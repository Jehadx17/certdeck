# Kept free of rest_framework.views imports: DRF imports DEFAULT_PERMISSION_CLASSES while loading its views module.
from rest_framework.exceptions import APIException
from rest_framework.permissions import BasePermission


class ApiError(APIException):
    def __init__(self, status, message):
        self.status_code = status
        super().__init__(message)


class BearerToken(BasePermission):
    """Finds the active account whose token hash matches; views read it as request.account."""

    def has_permission(self, request, view):
        from .models import Account, token_hash  # models aren't ready when DRF loads this module

        given = request.headers.get("Authorization", "")
        if given.startswith("Bearer ") and len(given) > 7:
            # A lookup by sha256 of a 256-bit random token: timing reveals nothing useful about other tokens.
            account = Account.objects.filter(token_hash=token_hash(given[7:]), active=True).first()
            if account:
                request.account = account
                return True
        raise ApiError(401, "invalid or missing API token")
