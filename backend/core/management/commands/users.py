import argparse
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
  users create sara                 student with the default $10/month cap; prints the token
  users create sara --cap 20        another cap ('none' = no cap)
  users list                        everyone, with this month's AI spend
  users cap sara 15                 change a cap ('none' = no cap)
  users rotate sara                 new token (the old one stops working); prints it
  users code sara                   one-time sign-in code for the phone, valid 24 h (signing in replaces the token)
  users disable sara / enable sara  block or restore access (data is kept)
  users delete sara --yes           delete the account and ALL its data"""

    def create_parser(self, *args, **kwargs):
        parser = super().create_parser(*args, **kwargs)
        parser.formatter_class = argparse.RawDescriptionHelpFormatter
        return parser

    def add_arguments(self, parser):
        parser.add_argument("action", choices=["create", "list", "cap", "rotate", "code", "disable", "enable", "delete"])
        parser.add_argument("name", nargs="?")
        parser.add_argument("value", nargs="?", help="cap in dollars, or 'none' (for `cap`)")
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
            if not name:
                raise CommandError("name required")
            if Account.objects.filter(name=name).exists():
                raise CommandError(f"{name!r} already exists")
            account = Account(name=name, role=role,
                              cap_usd=_cap(cap) if cap is not None else (None if role == "owner" else DEFAULT_CAP))
            token = account.new_token()
            account.save()
            self.stdout.write(f"Created {role} {name!r} (cap: {account.cap_usd or 'none'}).\nToken: {token}")
            return
        account = self._get(name)
        if action == "cap":
            if value is None:
                raise CommandError("usage: users cap <name> <dollars|none>")
            account.cap_usd = _cap(value)
            account.save(update_fields=["cap_usd"])
            self.stdout.write(f"{name}: cap {account.cap_usd or 'none'}")
        elif action == "rotate":
            token = account.new_token()
            account.save(update_fields=["token_hash"])
            self.stdout.write(f"New token for {name}: {token}")
        elif action == "code":
            code = account.new_login_code()
            account.save(update_fields=["login_code_hash", "login_code_expires"])
            self.stdout.write(f"Sign-in code for {name}: {code}\n(type it in the app's first screen within 24 hours; works once)")
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
