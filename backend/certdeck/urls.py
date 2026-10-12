from django.http import JsonResponse
from django.urls import path

from core import views

urlpatterns = [
    path("api/health", views.health),
    path("api/sync", views.sync),
    path("api/media/<str:name>", views.media),
    path("api/ai/generate", views.generate),
    path("api/ai/explain", views.explain),
    path("api/ai/variants", views.variants),
    path("api/ai/analyze", views.analyze),
    path("api/fsrs/optimize", views.optimize),
    path("api/usage", views.usage),
    path("api/export", views.export),
    path("api/import", views.import_),
]


def handler404(request, exception):
    return JsonResponse({"error": "not found"}, status=404)


def handler500(request):
    return JsonResponse({"error": "internal server error"}, status=500)
