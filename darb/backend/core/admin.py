"""The admin page: look up an account, check its entitlement, reset its AI quota, suspend or restore it, see AI spend,
and change the AI caps without an app update. Reports read the replica when DATABASE_REPLICA_URL is set."""
from datetime import timedelta

from django.conf import settings
from django.contrib import admin, messages
from django.db.models import Count, Sum
from django.db.models.functions import TruncDate
from django.utils.timezone import now as tz_now

from . import ai, billing, signin
from .models import Account, AiCall, Config, Device

admin.site.site_header = admin.site.site_title = "Darb admin"


def _reports_db():
    return "replica" if "replica" in settings.DATABASES else "default"


class DeviceInline(admin.TabularInline):
    model = Device
    fields = ("platform", "created", "last_seen")
    readonly_fields = fields
    extra = 0
    can_delete = True  # deleting a device signs that phone out


@admin.register(Account)
class AccountAdmin(admin.ModelAdmin):
    list_display = ("email", "public_id", "created", "plus", "premium_until", "ai_this_month", "guardian", "active")
    search_fields = ("email", "public_id", "google_sub", "apple_sub", "guardian_email")
    list_filter = ("active",)
    readonly_fields = ("public_id", "google_sub", "apple_sub", "seq", "created", "premium_until", "guardian_ok_at",
                       "ai_this_month", "ai_limits")
    fields = ("email", "name", "public_id", "birth_year", "guardian_email", "guardian_ok_at", "premium_until",
              "cap_usd", "ai_this_month", "ai_limits", "quota_reset_at", "active", "suspended", "created")
    inlines = [DeviceInline]
    actions = ["reset_ai_quota", "suspend", "restore", "refresh_subscription"]

    @admin.display(boolean=True, description="Plus")
    def plus(self, a):
        return billing.is_premium(a)

    @admin.display(description="AI $ this month")
    def ai_this_month(self, a):
        return f"${ai.spent(a):.4f}"

    @admin.display(description="cap / calls per day")
    def ai_limits(self, a):
        cap, per_day = ai.limits(a)
        return f"${cap:.2f} / {per_day}"

    @admin.display(description="guardian")
    def guardian(self, a):
        return "pending" if signin.needs_guardian(a) else "ok" if signin.is_minor(a) else ""

    @admin.action(description="Reset AI quota (spend counts from now)")
    def reset_ai_quota(self, request, qs):
        n = qs.update(quota_reset_at=tz_now())
        messages.info(request, f"AI quota reset for {n} account(s).")

    @admin.action(description="Suspend (blocks sign-in and the API; data kept)")
    def suspend(self, request, qs):
        qs.update(active=False, suspended="suspended by admin")

    @admin.action(description="Restore suspended accounts")
    def restore(self, request, qs):
        qs.update(active=True, suspended="")

    @admin.action(description="Re-read the subscription from RevenueCat")
    def refresh_subscription(self, request, qs):
        for a in qs:
            billing.refresh(a)


@admin.register(Config)
class ConfigAdmin(admin.ModelAdmin):
    list_display = ("free_cap_usd", "paid_cap_usd", "free_daily_ai", "paid_daily_ai", "daily_spend_alert_usd")

    def has_add_permission(self, request):
        return not Config.objects.exists()


@admin.register(AiCall)
class AiCallAdmin(admin.ModelAdmin):
    """Every AI call with its tokens and cost; the list page shows the spend summary on top."""
    list_display = ("created", "user", "endpoint", "model", "input_tokens", "output_tokens", "cost_usd", "batch", "ok")
    list_filter = ("endpoint", "model", "batch", "ok")
    search_fields = ("user__email", "user__public_id")
    date_hierarchy = "created"
    readonly_fields = [f.name for f in AiCall._meta.fields]
    change_list_template = "admin/core/aicall/change_list.html"

    def has_add_permission(self, request):
        return False

    def changelist_view(self, request, extra_context=None):
        calls = AiCall.objects.using(_reports_db())
        month, last30 = calls.filter(created__gte=ai.month_start()), calls.filter(created__gte=tz_now() - timedelta(days=30))
        accounts = Account.objects.using(_reports_db())
        paying = accounts.filter(premium_until__gt=tz_now()).count()
        total = float(month.aggregate(s=Sum("cost_usd"))["s"] or 0)
        extra_context = {**(extra_context or {}), "spend": {
            "month_usd": total,
            "per_paying_user": total / paying if paying else None,
            "accounts": accounts.count(), "paying": paying,
            "by_endpoint": list(month.values("endpoint").annotate(usd=Sum("cost_usd"), n=Count("id")).order_by("-usd")),
            "by_day": list(last30.annotate(day=TruncDate("created")).values("day").annotate(usd=Sum("cost_usd"), n=Count("id")).order_by("-day")),
            "top_users": list(month.values("user__email", "user__public_id").annotate(usd=Sum("cost_usd")).order_by("-usd")[:10]),
        }}
        return super().changelist_view(request, extra_context)
