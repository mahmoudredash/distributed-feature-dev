#!/usr/bin/env bash
# End-to-end test for orch.py with a fake ssh/tmux and fake agents.
# Needs only bash, git and python3. Runs entirely in a temp dir.
#   bash tests/e2e.sh
set -euo pipefail
ORCH="$(cd "$(dirname "$0")/.." && pwd)/skills/distributed-feature-dev/scripts/orch.py"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export HOME="$T/home" PATH="$T/bin:$PATH" GIT_CONFIG_NOSYSTEM=1
mkdir -p "$HOME" "$T/bin"
git config --global user.email test@example.com; git config --global user.name test
git config --global init.defaultBranch main
PASS=0; FAIL=0
ok()  { echo "  ok   - $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL - $1"; FAIL=$((FAIL + 1)); }
expect() { if ( set +o pipefail; eval "$2" ); then ok "$1"; else bad "$1"; fi; }

# fake ssh: drop options + host, run the command locally. fake tmux: run synchronously.
cat > "$T/bin/ssh" <<'X'
#!/bin/bash
while [[ "$1" == -* ]]; do shift; shift; done; shift; exec bash -c "$1"
X
cat > "$T/bin/tmux" <<'X'
#!/bin/bash
[ "$1" = new-session ] && bash -c "${@: -1}"; exit 0
X
# fake agent: behaviour selected by markers in the prompt
cat > "$T/fake.sh" <<'X'
#!/bin/bash
AG=$1; P=$2; shift 2; echo "fake $AG args=$*"
case "$P" in
 *"Rebase needed"*) git rebase origin/feature/login >/dev/null 2>&1; printf 'a\nb\n' > shared.txt
                    git add shared.txt; GIT_EDITOR=true git rebase --continue >/dev/null;;
 *"Self-fix"*)      rm -f BROKEN;;
 *"independent QA"*) printf 'VERDICT: PASS\n' > ORCH_QA_REPORT.md; echo junk > qa_junk.txt;;
 *MODE:quota*)      echo "Error: usage limit reached"; exit 1;;
 *MODE:broken*)     echo x > brk.txt; touch BROKEN;;
 *MODE:shared-a*)   echo a > shared.txt;;
 *MODE:shared-b*)   echo b > shared.txt;;
 *)                 echo ok > api.txt;;
esac
X
chmod +x "$T"/bin/* "$T/fake.sh"

git init -q --bare "$T/origin.git"
git clone -q "$T/origin.git" "$T/mgr" 2>/dev/null; cd "$T/mgr"
echo hi > README; git add .; git commit -qm init; git push -q origin main
mkdir .orch
cat > .orch/config.json <<X
{"base_branch":"main","repo_url":"$T/origin.git","verify":"test ! -f BROKEN","self_fix_attempts":2,
 "protected_paths":["tests/contract/*"],
 "agents":{
  "claude":{"cmd":"bash $T/fake.sh claude \"\$(cat {prompt_file})\" {model_flag}","model_flag":"--model {model}","quota_patterns":"usage limit","binary":"git"},
  "opencode":{"cmd":"bash $T/fake.sh opencode \"\$(cat {prompt_file})\"","binary":"git"},
  "agy":{"cmd":"bash $T/fake.sh agy \"\$(cat {prompt_file})\"","binary":"git"}},
 "workers":[{"name":"pc1","host":"a","agents":["claude","opencode"],"repo_path":"~/w1/repo","max_slots":3},
            {"name":"pc2","host":"b","agents":["agy","opencode"],"repo_path":"~/w2/repo","max_slots":3}]}
X
O="python3 $ORCH"
for m in api broken quota shared-a shared-b; do echo "MODE:$m" > "$T/p_$m.md"; done
echo "check it" > "$T/p_qa.md"

echo "# setup"
expect "doctor passes"                 "$O doctor | grep -q '^OK'"
$O init --feature login >/dev/null
expect "feature branch pushed"         "git ls-remote --heads origin feature/login | grep -q ."

echo "# dispatch + worker pipeline"
$O dispatch --task api --worker pc1 --agent claude --model big --prompt-file "$T/p_api.md" >/dev/null
$O dispatch --task brk --worker pc2 --agent agy   --prompt-file "$T/p_broken.md" >/dev/null
$O dispatch --task quo --worker pc1 --agent claude --model big --prompt-file "$T/p_quota.md" >/dev/null
$O dispatch --task sa  --worker pc2 --agent opencode --prompt-file "$T/p_shared-a.md" >/dev/null
$O dispatch --task sb  --worker pc1 --agent opencode --prompt-file "$T/p_shared-b.md" >/dev/null
S=$($O status)
expect "model flag passed to agent"    "grep -q -- '--model big' $HOME/.orch/api.agent.log"
expect "preamble prepended"            "grep -q 'Working conditions' $HOME/.orch/api.prompt.md"
expect "api done green"                "echo \"\$S\" | grep -Eq '^api .*done +green'"
expect "self-fix turned red into green" "echo \"\$S\" | grep -Eq '^brk .*done +green' && grep -q 'self-fix 1' <(git -C $HOME/w2/repo log --oneline origin/feature/login--brk)"
expect "quota detected"                "echo \"\$S\" | grep -Eq '^quo .*quota'"

echo "# quota handling"
expect "same agent+model blocked"      "! $O dispatch --task quo --worker pc1 --agent claude --model big --prompt-file $T/p_api.md 2>/dev/null"
$O reject --task quo --issue quota-handoff --model small --prompt-file "$T/p_api.md" >/dev/null
$O status >/dev/null
expect "fallback model allowed + done" "$O status | grep -Eq '^quo .*done +green'"

echo "# independent QA"
expect "self-review refused"           "! $O qa --task api --worker pc1 --agent claude --prompt-file $T/p_qa.md 2>/dev/null"
$O qa --task api --worker pc2 --agent opencode --prompt-file "$T/p_qa.md" >/dev/null; $O status >/dev/null
expect "QA report delivered"           "$O report --task api-qa1 | grep 'VERDICT: PASS' >/dev/null"
expect "QA changes discarded"          "[ ! -e $HOME/w2/repo.wt/api-qa1/qa_junk.txt ]"

echo "# review / accept / conflicts"
expect "accept refuses running/quota"  "python3 - <<P
import json; s=json.load(open('.orch/state.json')); s['tasks']['quo']['status']='quota'; json.dump(s,open('.orch/state.json','w'))
P
! $O accept --task quo 2>/dev/null"
python3 - <<P
import json; s=json.load(open('.orch/state.json')); s['tasks']['quo']['status']='done'; json.dump(s,open('.orch/state.json','w'))
P
for t in api brk quo sa; do $O accept --task $t >/dev/null; done
expect "merges landed"                 "git show origin/feature/login:api.txt >/dev/null && git show origin/feature/login:brk.txt >/dev/null"
expect "worker worktree cleaned"       "[ ! -d $HOME/w1/repo.wt/api ]"
set +e; $O accept --task sb >/dev/null 2>&1; RC=$?; set -e
expect "conflict -> exit 2"            "[ $RC = 2 ]"
$O reject --task sb --issue merge-conflict --prompt-file "$T/p_shared-b.md" >/dev/null; $O status >/dev/null
$O accept --task sb >/dev/null
expect "auto-rebase resolved conflict" "[ \"\$(git show origin/feature/login:shared.txt | tr '\n' ' ')\" = 'a b ' ]"
expect "reject on merged task refused" "! $O reject --task sb --issue x --prompt-file $T/p_api.md 2>/dev/null"

echo "# protected paths"
git checkout -q -b evil origin/feature/login; mkdir -p tests/contract; echo t > tests/contract/x.txt
git add .; git commit -qm evil; git push -q origin evil:feature/login--evil; git checkout -q main
python3 - <<P
import json; s=json.load(open('.orch/state.json'))
s['tasks']['evil']=dict(s['tasks']['api'], branch='feature/login--evil', history=[], status='done')
json.dump(s,open('.orch/state.json','w'))
P
expect "protected change flagged"      "$O review --task evil | grep -q 'PROTECTED FILES CHANGED'"

echo "# round limits"
$O dispatch --task lim --worker pc2 --agent agy --prompt-file "$T/p_api.md" >/dev/null; $O status >/dev/null
for i in 1 2 3; do $O reject --task lim --issue same --prompt-file "$T/p_api.md" >/dev/null; $O status >/dev/null; done
set +e; $O reject --task lim --issue same --prompt-file "$T/p_api.md" >/dev/null 2>&1; RC=$?; set -e
expect "4th round on same issue -> TAKEOVER (exit 3)" "[ $RC = 3 ]"

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
