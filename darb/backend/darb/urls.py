from django.http import JsonResponse
from django.urls import path

from core import views

urlpatterns = [
    path("api/health", views.health),
    path("api/me", views.me),
    path("api/sync", views.sync),
    path("api/ai/explain", views.explain),
    # uploads (subscribers): resumable PDF/photo uploads -> cards, practice and sheets for an exam
    path("api/upload/<str:material_id>/<int:n>", views.upload),
    path("api/upload/<str:material_id>/<int:n>/done", views.upload_done),
    path("api/college/page/<str:material_id>/<int:page>", views.page_image),
    path("api/college/process", views.process),
    path("api/college/prepare", views.prepare),
    path("api/college/suggest_scope", views.suggest_scope),
    path("api/college/prioritize", views.prioritize),
    path("api/college/grade", views.grade),
    path("api/college/practice", views.practice),
    path("api/college/night", views.night),
]


def handler404(request, exception):
    return JsonResponse({"error": "not found"}, status=404)


def handler500(request):
    return JsonResponse({"error": "internal server error"}, status=500)
