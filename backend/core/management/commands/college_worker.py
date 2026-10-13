import time

from django.core.management.base import BaseCommand
from django.db import close_old_connections

from core.college import worker_tick


class Command(BaseCommand):
    help = "Processes uploaded course material and prepares assessments (runs forever in certdeck-college)."

    def add_arguments(self, parser):
        parser.add_argument("--once", action="store_true", help="one pass, then exit")

    def handle(self, *args, once=False, **options):
        while True:
            close_old_connections()
            did = worker_tick()
            if once:
                return
            time.sleep(2 if did else 10)
