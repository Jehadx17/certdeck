import json
from pathlib import Path

from django.core.management.base import BaseCommand, CommandError

from core import content, packs
from core.models import Pack


class Command(BaseCommand):
    help = """The content pipeline (docs/DARB-PACKS.md):
  packs run <slug>...        one pass per pack: collect ended batches, submit the next stage (re-run until complete)
  packs run --all            every blueprint in darb/content/blueprints
  packs status               items per status, error rate, cost per pack
  packs build <slug> --out DIR   encrypt the verified items as a new version (+ sample) into DIR (upload to R2/CDN)
  packs publish <slug> / unpublish <slug>"""

    def add_arguments(self, parser):
        parser.add_argument("action", choices=["run", "status", "build", "publish", "unpublish", "demo"])
        parser.add_argument("slugs", nargs="*")
        parser.add_argument("--all", action="store_true")
        parser.add_argument("--out", default="")

    def handle(self, action, slugs, all=False, out="", **options):
        if all:
            slugs = sorted(p.stem for p in content.BLUEPRINTS.glob("*.json"))
        if action == "demo":  # development only: a small published pack to walk through the app
            from django.conf import settings
            from core.models import PackItem
            if not settings.DEBUG:
                raise CommandError("demo packs are for development (DJANGO_DEBUG=true)")
            pack, _ = Pack.objects.update_or_create(slug="demo-quant", defaults=dict(
                title_ar="القدرات - كمي (تجريبي)", title_en="Qudurat - quantitative (demo)", segments=["high"],
                exams=["qudurat"], published=True, sample_size=8, topics=[
                    {"id": "t1", "title_ar": "الحساب", "title_en": "Arithmetic", "weight": .6},
                    {"id": "t2", "title_ar": "النسبة والتناسب", "title_en": "Ratio", "weight": .4}]))
            PackItem.objects.filter(pack=pack).delete()
            for n in range(1, 41):
                a, b = 3 + n % 7, 4 + n % 5
                if n % 2:
                    q, ans, topic = f"ما ناتج {a} × {b}؟", a * b, "t1"
                    opts = [a * b, a * b + a, a * b - b, a + b]
                    hint = "اضرب العددين."
                else:
                    q, ans, topic = f"إذا كان ثمن {a} أقلام {a * b} ريالًا، فما ثمن قلم واحد؟", b, "t2"
                    opts = [b, b + 1, a, a * b]
                    hint = "اقسم الثمن على عدد الأقلام."
                opts = [str(o) for o in dict.fromkeys(opts)][:4] + [str(ans + k) for k in (10, 20, 30)]
                opts = opts[:4]
                PackItem.objects.create(pack=pack, n=n, status="verified", source="dev-demo", data={
                    "type": "mcq", "question": q, "options": opts, "correct": [opts.index(str(ans))],
                    "explanation": f"الإجابة {ans}.", "hint": hint, "topic": topic, "difficulty": 1 + n % 3})
            slugs, out = ["demo-quant"], out or "/tmp/darb-cdn"
            action = "build"
        if action == "run":
            for slug in slugs:
                self.stdout.write(content.advance(slug))
        elif action == "status":
            for p in Pack.objects.order_by("slug"):
                self.stdout.write(json.dumps(content.summary(p), ensure_ascii=False))
        elif action == "build":
            if not out:
                raise CommandError("--out DIR required")
            for slug in slugs:
                pack = Pack.objects.get(slug=slug)
                blob, sample = packs.build(pack)
                d = Path(out) / slug
                d.mkdir(parents=True, exist_ok=True)
                (d / f"{pack.version}.dpk").write_bytes(blob)
                (d / f"sample-{pack.version}.json.gz").write_bytes(sample)
                self.stdout.write(f"{slug} v{pack.version}: {pack.items} items, {len(blob)} bytes -> {d}")
        else:
            Pack.objects.filter(slug__in=slugs).update(published=action == "publish")
