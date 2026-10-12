import json

from django.core.management.base import BaseCommand

from core.stats import optimize


class Command(BaseCommand):
    help = "Fit FSRS parameters to all review docs and save the fsrs_params doc (run weekly from a timer)."

    def handle(self, *args, **options):
        self.stdout.write(json.dumps(optimize()))
