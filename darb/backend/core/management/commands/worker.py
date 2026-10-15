from django.core.management.base import BaseCommand

from core.jobs import work


class Command(BaseCommand):
    help = "Runs queued jobs (uploads, preparations, re-prioritizing, autopilot, re-teach) and maintenance, forever."

    def add_arguments(self, parser):
        parser.add_argument("--once", action="store_true", help="one job (if due) and one maintenance pass, then exit")

    def handle(self, *args, once=False, **options):
        work(once=once)
