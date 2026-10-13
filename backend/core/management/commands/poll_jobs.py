from django.core.management.base import BaseCommand

from core.ai import poll_jobs, queue_diagrams


class Command(BaseCommand):
    help = "Finish background (Batch API) jobs whose batch has ended, then queue diagram jobs for new cards. Run every minute by certdeck-batches."

    def handle(self, *args, **options):
        if n := poll_jobs():
            self.stdout.write(f"finished {n} job(s)")
        if n := queue_diagrams():
            self.stdout.write(f"queued {n} diagram job(s)")
