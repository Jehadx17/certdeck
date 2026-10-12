# Kept free of rest_framework.views imports: DRF imports DEFAULT_PERMISSION_CLASSES while loading its views module.
import hmac

from django.conf import settings
from rest_framework.exceptions import APIException
from rest_framework.permissions import BasePermission


class ApiError(APIException):
    def __init__(self, status, message):
        self.status_code = status
        super().__init__(message)


class BearerToken(BasePermission):
    def has_permission(self, request, view):
        token = settings.CERTDECK_API_TOKEN.encode()
        given = request.headers.get("Authorization", "").encode()
        if token and hmac.compare_digest(given, b"Bearer " + token):
            return True
        raise ApiError(401, "invalid or missing API token")
