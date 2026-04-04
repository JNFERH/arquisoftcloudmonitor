from django.db import models
from django.contrib.auth.models import User

class Organization(models.Model):
    name = models.CharField(max_length=200, unique=True)
    created_at = models.DateTimeField(auto_now_add=True)

    def __str__(self):
        return self.name

class UserOrganization(models.Model):
    ROLE_CHOICES = [
        ('admin', 'Admin'),
        ('member', 'Member'),
    ]
    user_id = models.IntegerField(unique=True)
    organization = models.ForeignKey(Organization, on_delete=models.CASCADE)
    role = models.CharField(max_length=10, choices=ROLE_CHOICES, default='member')

    def __str__(self):
        return f"User {self.user_id} -> {self.organization.name} ({self.role})"

class CostRecord(models.Model):
    organization = models.ForeignKey(Organization, on_delete=models.CASCADE)
    account_id = models.CharField(max_length=100)
    resource_group = models.CharField(max_length=200)
    service_type = models.CharField(max_length=200)
    date = models.DateField()
    cost_amount = models.DecimalField(max_digits=10, decimal_places=4)
    currency = models.CharField(max_length=10)
    region = models.CharField(max_length=100)
    project = models.CharField(max_length=100, blank=True, null=True)
    env = models.CharField(max_length=50, blank=True, null=True)
    raw_resource_id = models.TextField(blank=True, null=True)

    def __str__(self):
        return f"{self.service_type} | {self.resource_group} | {self.date} | {self.cost_amount} {self.currency}"