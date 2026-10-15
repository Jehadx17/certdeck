import json

from django.core.management.base import BaseCommand

from core import autopilot
from core.models import Account


class Command(BaseCommand):
    help = "Run the autopilot once for every active account (the worker also does this daily)."

    def add_arguments(self, parser):
        parser.add_argument("--no-ai", action="store_true", help="rules only, no AI supervisor call")

    def handle(self, *args, no_ai=False, **options):
        for user in Account.objects.filter(active=True):
            out = autopilot.run(user, use_ai=not no_ai)
            self.stdout.write(f"{user.name}: " + ("skipped" if out is None else json.dumps({k: v for k, v in out.items() if k != "history"})))
