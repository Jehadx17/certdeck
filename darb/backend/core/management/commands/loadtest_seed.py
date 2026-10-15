from datetime import timedelta

from django.core.management.base import BaseCommand
from django.utils.timezone import now

from core.models import Account, Device


class Command(BaseCommand):
    help = "Load test only: N accounts (half Plus) with one device each; prints one token per line."

    def add_arguments(self, parser):
        parser.add_argument("--accounts", type=int, default=2000)

    def handle(self, *args, accounts=2000, **options):
        for i in range(accounts):
            a = Account.objects.create(email=f"load{i}@example.com", birth_year=2000,
                                       premium_until=now() + timedelta(days=30) if i % 2 else None)
            self.stdout.write(Device.issue(a, "android")[1])
