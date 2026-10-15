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
        parser.add_argument("action", choices=["run", "status", "build", "publish", "unpublish"])
        parser.add_argument("slugs", nargs="*")
        parser.add_argument("--all", action="store_true")
        parser.add_argument("--out", default="")

    def handle(self, action, slugs, all=False, out="", **options):
        if all:
            slugs = sorted(p.stem for p in content.BLUEPRINTS.glob("*.json"))
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
