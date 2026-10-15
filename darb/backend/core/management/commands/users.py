from django.core.management.base import BaseCommand, CommandError
from django.db.models import Sum

from core.ai import month_start
from core.models import Account, AiCall, Device


class Command(BaseCommand):
    help = """Accounts from the server shell (students sign in with Google/Apple; this is for tests and support):
  users create a@b.com      an account with one device; prints its token (shown once)
  users token a@b.com       another device token for the account
  users list                everyone, with this month's AI spend
  users disable a@b.com / enable a@b.com
  users delete a@b.com --yes   the account and ALL its data"""

    def add_arguments(self, parser):
        parser.add_argument("action", choices=["create", "token", "list", "disable", "enable", "delete"])
        parser.add_argument("email", nargs="?")
        parser.add_argument("--yes", action="store_true")

    def _get(self, email):
        a = Account.objects.filter(email=email).first()
        if not a:
            raise CommandError(f"no account {email!r}")
        return a

    def handle(self, action, email=None, yes=False, **options):
        if action == "list":
            for a in Account.objects.order_by("created"):
                usd = AiCall.objects.filter(user=a, created__gte=month_start()).aggregate(s=Sum("cost_usd"))["s"] or 0
                self.stdout.write(f"{a.public_id}  {a.email or '-':30}  active={a.active}  premium_until={a.premium_until}  ai=${usd:.4f}")
            return
        if not email:
            raise CommandError("email required")
        if action == "create":
            if Account.objects.filter(email=email).exists():
                raise CommandError("exists")
            _, token = Device.issue(Account.objects.create(email=email, name=email.split("@")[0]), "shell")
            self.stdout.write(f"Token: {token}")
        elif action == "token":
            _, token = Device.issue(self._get(email), "shell")
            self.stdout.write(f"Token: {token}")
        elif action in ("disable", "enable"):
            Account.objects.filter(pk=self._get(email).pk).update(active=action == "enable")
        elif action == "delete":
            if not yes:
                raise CommandError("add --yes to delete the account and all its data")
            self._get(email).delete()
