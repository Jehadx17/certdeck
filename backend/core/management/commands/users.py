import argparse
import getpass
from decimal import Decimal, InvalidOperation

from django.core.management.base import BaseCommand, CommandError
from django.db.models import Sum

from core.ai import month_start
from core.models import Account, AiCall

DEFAULT_CAP = Decimal("10")


def _cap(value):
    if value.lower() in ("none", "no", "off"):
        return None
    try:
        cap = Decimal(value)
    except InvalidOperation:
        raise CommandError(f"cap must be dollars (e.g. 10) or 'none', not {value!r}")
    if cap < 0:
        raise CommandError("cap can't be negative")
    return cap


class Command(BaseCommand):
    help = """Manage accounts. Examples:
  users create sara a@b.com         student with the default $10/month cap; asks for the password
  users create sara a@b.com --cap 20  another cap ('none' = no cap)
  users list                        everyone, with this month's AI spend
  users cap sara 15                 change a cap ('none' = no cap)
  users login sara a@b.com          change the email + password (asked for) a person signs in with
  users signout sara                sign out every device (they sign in again with email + password)
  users disable sara / enable sara  block or restore access (data is kept)
  users delete sara --yes           delete the account and ALL its data"""

    def create_parser(self, *args, **kwargs):
        parser = super().create_parser(*args, **kwargs)
        parser.formatter_class = argparse.RawDescriptionHelpFormatter
        return parser

    def add_arguments(self, parser):
        parser.add_argument("action", choices=["create", "list", "cap", "login", "signout", "disable", "enable", "delete"])
        parser.add_argument("name", nargs="?")
        parser.add_argument("value", nargs="?", help="cap in dollars or 'none' (`cap`); the email (`create`, `login`)")
        parser.add_argument("--cap", default=None, help="monthly AI budget in dollars, or 'none' (create)")
        parser.add_argument("--role", default="student", choices=["student", "owner"])
        parser.add_argument("--yes", action="store_true", help="confirm delete")

    def _get(self, name):
        if not name:
            raise CommandError("name required")
        try:
            return Account.objects.get(name=name)
        except Account.DoesNotExist:
            raise CommandError(f"no account {name!r} (see: users list)")

    def handle(self, action, name=None, value=None, cap=None, role="student", yes=False, **options):
        if action == "list":
            spend = dict(AiCall.objects.filter(created__gte=month_start()).values("user")
                         .annotate(s=Sum("cost_usd")).values_list("user", "s"))
            self.stdout.write(f"{'name':20} {'role':8} {'active':6} {'cap':>8} {'this month':>10}")
            for a in Account.objects.order_by("id"):
                c = "none" if a.cap_usd is None else f"${a.cap_usd}"
                self.stdout.write(f"{a.name:20} {a.role:8} {str(a.active):6} {c:>8} ${float(spend.get(a.id) or 0):>9.2f}")
            return
        if action == "create":
            if not name or not value:
                raise CommandError("usage: users create <name> <email>")
            if Account.objects.filter(name=name).exists():
                raise CommandError(f"{name!r} already exists")
            account = Account(name=name, role=role,
                              cap_usd=_cap(cap) if cap is not None else (None if role == "owner" else DEFAULT_CAP))
            self.stdout.write(f"Creating {role} {name!r} (cap: {account.cap_usd or 'none'}).")
            action = "login"  # asks for the password, then saves
        else:
            account = self._get(name)
        if action == "cap":
            if value is None:
                raise CommandError("usage: users cap <name> <dollars|none>")
            account.cap_usd = _cap(value)
            account.save(update_fields=["cap_usd"])
            self.stdout.write(f"{name}: cap {account.cap_usd or 'none'}")
        elif action == "signout":
            n, _ = account.tokens.all().delete()
            self.stdout.write(f"{name}: signed out of {n} device(s)")
        elif action == "login":
            if not value:
                raise CommandError("usage: users login <name> <email>")
            password = getpass.getpass("Password: ")
            if len(password) < 8:
                raise CommandError("the password needs at least 8 characters")
            account.email = value.strip().lower()
            account.set_password(password)
            account.save()
            self.stdout.write(f"{name} signs in with {account.email}")
        elif action in ("disable", "enable"):
            account.active = action == "enable"
            account.save(update_fields=["active"])
            self.stdout.write(f"{name}: {'active' if account.active else 'disabled'}")
        elif action == "delete":
            if not yes:
                raise CommandError(f"this deletes {name!r} and all their data; add --yes to confirm")
            if account.role == "owner" and Account.objects.filter(role="owner").count() == 1:
                raise CommandError("refusing to delete the only owner")
            from core.ingest import delete_account_files
            delete_account_files(account)
            account.delete()
            self.stdout.write(f"Deleted {name} and their data.")
