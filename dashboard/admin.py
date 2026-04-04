from django.contrib import admin
from .models import Organization, UserOrganization, CostRecord

admin.site.register(Organization)
admin.site.register(UserOrganization)
admin.site.register(CostRecord)