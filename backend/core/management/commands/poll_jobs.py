from django.core.management.base import BaseCommand

from core.ai import poll_jobs


class Command(BaseCommand):
    help = "Finish background (Batch API) generations whose batch has ended. Run every minute by certdeck-batches."

    def handle(self, *args, **options):
        if n := poll_jobs():
            self.stdout.write(f"finished {n} job(s)")
