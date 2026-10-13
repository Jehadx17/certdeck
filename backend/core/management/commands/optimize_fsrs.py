import json

from django.core.management.base import BaseCommand

from core.models import Account
from core.stats import optimize


class Command(BaseCommand):
    help = "Fit FSRS parameters to each user's review docs and save their fsrs_params doc (run weekly from a timer)."

    def handle(self, *args, **options):
        for user in Account.objects.filter(active=True):
            self.stdout.write(f"{user.name}: {json.dumps(optimize(user))}")
