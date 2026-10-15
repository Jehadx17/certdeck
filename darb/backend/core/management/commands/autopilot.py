import json

from django.core.management.base import BaseCommand

from core import autopilot
from core.models import Account


class Command(BaseCommand):
    help = "Run the autopilot once for every active account (the worker runs it per active account)."

    def handle(self, *args, **options):
        for user in Account.objects.filter(active=True):
            out = autopilot.run(user)
            self.stdout.write(f"{user}: " + ("skipped" if out is None else json.dumps({k: v for k, v in out.items() if k != "history"})))
