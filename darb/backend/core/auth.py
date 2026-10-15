# Kept free of rest_framework.views imports: DRF imports DEFAULT_PERMISSION_CLASSES while loading its views module.
from rest_framework.exceptions import APIException
from rest_framework.permissions import BasePermission


class ApiError(APIException):
    """An error the app shows. [code] is a stable machine-readable reason (premium, guardian, budget, too_young, ...)."""

    def __init__(self, status, message, code=None):
        self.status_code = status
        self.error_code = code
        super().__init__(message)


# What a minor can use before their guardian confirms: who am I, the guardian step, signing out, deleting the account.
GUARDIAN_FREE = {"/api/me", "/api/account", "/api/account/guardian", "/api/auth/signout"}


class BearerToken(BasePermission):
    """Finds the device whose token hash matches; views read request.account and request.device."""

    def has_permission(self, request, view):
        from .models import Device, token_hash  # models aren't ready when DRF loads this module

        given = request.headers.get("Authorization", "")
        if given.startswith("Bearer ") and len(given) > 7:
            # A lookup by sha256 of a 256-bit random token: timing reveals nothing useful about other tokens.
            device = Device.objects.select_related("account").filter(token_hash=token_hash(given[7:])).first()
            if device and device.account.active:
                request.device, request.account = device, device.account
                from .signin import needs_guardian
                if needs_guardian(device.account) and request.path not in GUARDIAN_FREE:
                    raise ApiError(403, "Waiting for your guardian to confirm.", code="guardian")
                return True
        raise ApiError(401, "invalid or missing token")
