import json
from django.shortcuts import render, redirect
from django.contrib.auth.decorators import login_required
from django.contrib import messages
from django.db.models import Sum
from .forms import UploadJSONForm
from .models import CostRecord, UserOrganization

def get_user_organization(user):
    try:
        return UserOrganization.objects.using('costs_db').get(user_id=user.id)
    except UserOrganization.DoesNotExist:
        return None

@login_required
def dashboard_view(request):
    user_org = get_user_organization(request.user)

    if user_org is None:
        return render(request, 'dashboard/no_org.html')

    org = user_org.organization
    is_admin = user_org.role == 'admin'
    records = CostRecord.objects.using('costs_db').filter(organization=org)

    total_cost = records.aggregate(Sum('cost_amount'))['cost_amount__sum'] or 0
    by_service = list(records.values('service_type').annotate(total=Sum('cost_amount')).order_by('-total'))
    by_resource_group = list(records.values('resource_group').annotate(total=Sum('cost_amount')).order_by('-total'))
    by_region = list(records.values('region').annotate(total=Sum('cost_amount')).order_by('-total'))
    by_date = list(records.values('date').annotate(total=Sum('cost_amount')).order_by('date'))

    context = {
        'org': org,
        'is_admin': is_admin,
        'records': records,
        'total_cost': round(total_cost, 2),
        'by_service': json.dumps([{'label': x['service_type'], 'value': float(x['total'])} for x in by_service]),
        'by_resource_group': json.dumps([{'label': x['resource_group'], 'value': float(x['total'])} for x in by_resource_group]),
        'by_region': json.dumps([{'label': x['region'], 'value': float(x['total'])} for x in by_region]),
        'by_date': json.dumps([{'label': str(x['date']), 'value': float(x['total'])} for x in by_date]),
    }

    return render(request, 'dashboard/dashboard.html', context)

@login_required
def upload_json(request):
    user_org = get_user_organization(request.user)

    if user_org is None:
        return render(request, 'dashboard/no_org.html')

    if user_org.role != 'admin':
        messages.error(request, 'You do not have permission to upload files.')
        return redirect('dashboard')

    org = user_org.organization

    if request.method == 'POST':
        form = UploadJSONForm(request.POST, request.FILES)
        if form.is_valid():
            json_file = request.FILES['json_file']
            data = json.load(json_file)
            records = data.get('payload', {}).get('records', [])
            count = 0
            for item in records:
                CostRecord.objects.using('costs_db').create(
                    organization=org,
                    account_id=item.get('account_id', ''),
                    resource_group=item.get('resource_group', ''),
                    service_type=item.get('service_type', ''),
                    date=item.get('date'),
                    cost_amount=item.get('cost_amount', 0),
                    currency=item.get('currency', ''),
                    region=item.get('region', ''),
                    project=item.get('labels', {}).get('project', ''),
                    env=item.get('labels', {}).get('env', ''),
                    raw_resource_id=item.get('raw_resource_id', ''),
                )
                count += 1
            messages.success(request, f'{count} records uploaded successfully!')
            return redirect('dashboard')
    else:
        form = UploadJSONForm()
    return render(request, 'dashboard/upload.html', {'form': form})