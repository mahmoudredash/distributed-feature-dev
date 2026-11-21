# distributed-feature-dev

سكيل بتخلي agent واحد يبقى **قائد فريق تقني** لفريق agents موزعين على كذا جهاز.
توصفله فيتشر، فيخطط لها ويكتب العقود وتستات العقود ويقسم الشغل. بعدها
يشغّل المهام بالتوازي على أجهزتك عن طريق SSH، باستخدام Claude Code أو opencode
أو agy (Antigravity). كل جهاز بيشغّل عدد agents على قد الـ CPU والـ RAM بتوعه.
لما الشغل يخلص، القائد يبعته لمراجعة مستقلة، ويراجعه بنفسه، ويعمل merge، ويبعت
تعليمات إصلاح محددة. ولو نفس المشكلة اترفضت 3 مرات، بياخد المهمة ويصلحها بنفسه.

English: [README.md](README.md)

## بتعمل إيه

- **خطة ثم عقود ثم مهام:** الواجهات المشتركة والتستات اللي بتحدد المطلوب بتتحط
  على الـ feature branch الأول، فالمراجعة تبقى موضوعية. وملفات `AGENTS.md`
  و`docs/orch/plan.md` بتدي كل الـ agents نفس القواعد ونفس الصورة.
- **كل جهاز بيشتغل بكل طاقته:** كل مهمة في worktree منفصل، فالجهاز الواحد
  بيشغّل أكتر من agent في نفس الوقت. عدد الـ slots بيتحسب من الموارد الفعلية.
  وجهاز المدير نفسه ممكن يشتغل كـ worker.
- **الـ worker بيراجع شغله بنفسه:** بعد ما الـ agent يخلص، بيحصل commit، وبعده
  rebase تلقائي (والـ agent بيحل الـ conflicts)، وبعده بيشتغل أمر `verify`. لو
  فشل، الـ agent بيصلح بنفسه قبل ما يبلّغ المدير. وأي شغل اتعمل بيترفع دايماً
  كنقطة استكمال.
- **مراجعة مستقلة:** agent مختلف عن اللي كتب الكود بيراجع في وضع قراءة فقط،
  وبيكتب تقرير PASS أو FAIL.
- **التعامل مع نفاد الحصة:** بيكتشف رسائل الـ rate limit والـ quota لكل جهاز
  وagent وموديل، وينقل الشغل للبديل من الـ policy، والبديل بيكمّل من آخر نقطة.
- **حد لجولات الإصلاح:** 3 جولات لنفس المشكلة، و5 للمهمة كلها. بعد كده المدير
  بياخد المهمة ويصلحها بنفسه.
- **الأمان:** timeout، وكشف لو agent علّق، وملفات محمية، ومفيش أي merge على
  الـ branch الأساسي غير بموافقتك.

بتشتغل مع [adaptive-agent-skills](https://github.com/mahmoudredash/adaptive-agent-skills):
ملف `agent-model-policy.yaml` بيحدد الأدوار والموديلات وترتيب البدائل، والسكيل
دي بتنفّذه على الأجهزة. التفاصيل في
`skills/distributed-feature-dev/references/adaptive-agent-skills.md`.

## التثبيت

على جهاز **المدير** بـ Skills CLI:
```bash
npx skills add mahmoudredash/distributed-feature-dev --skill distributed-feature-dev --agent claude-code
```
أو يدوياً لـ Claude Code:
```bash
git clone https://github.com/mahmoudredash/distributed-feature-dev.git
cp -r distributed-feature-dev/skills/distributed-feature-dev ~/.claude/skills/
```
أجهزة الـ workers مش محتاجة السكيل. المطلوب عليها: git بصلاحية push، وtmux،
و`timeout` و`flock`، والـ agents متثبتة ومسجّل دخول فيها.

## الإعداد

1. جوه مشروعك: `mkdir -p .orch && cp <skill>/config.example.json .orch/config.json`
   واملا فيه الأجهزة، والـ agents اللي على كل جهاز، وأمر `verify` بتاعك
   (lint وbuild وتست).
2. اتأكد إن SSH من جهاز المدير لكل جهاز شغال بـ key من غير باسورد. والـ
   `repo_path` على كل جهاز لازم يكون clone مخصوص للنظام ده بس.
3. **راجع أمر `agy`:** أمر التشغيل من غير تفاعل والـ flag بتاع الموديل في
   ملف المثال مجرد مكان تحطهم فيه.
4. شغّل `python3 <skill>/scripts/orch.py doctor` وصلّح أي ERROR.
5. في Claude Code قول: «استخدم distributed-feature-dev وابني فيتشر كذا».

## التستات

```bash
bash tests/e2e.sh
```
بيجرب السيناريو كله بـ SSH وagents وهميين، والـ CI بيشغّله مع كل push.

## الأمان

ملف المثال بيشغّل Claude Code بـ `--dangerously-skip-permissions`، وده بيدي
الـ agent تحكم كامل في الجهاز. استخدم يوزر منفصل أو VM لكل جهاز، ولكل جهاز
deploy key ميقدرش يرفع غير على branches من نوع `feature/*--*`.
