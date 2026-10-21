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
        from .models import Token, token_hash  # models aren't ready when DRF loads this module

        given = request.headers.get("Authorization", "")
        if given.startswith("Bearer ") and len(given) > 7:
            # A lookup by sha256 of a 256-bit random token: timing reveals nothing useful about other tokens.
            found = Token.objects.select_related("account").filter(hash=token_hash(given[7:]), account__active=True).first()
            if found:
                request.account = found.account
                return True
        raise ApiError(401, "Signed out. Sign in again.")
