from django.urls import path
from . import views

urlpatterns = [
    path('', views.dashboard_view, name='dashboard'),
    path('upload/', views.upload_json, name='upload_json'),
]