import io
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
import matplotlib.patches as mpatches
from django.http import HttpResponse
from django.contrib.auth.decorators import login_required
from django.shortcuts import redirect
from django.db.models import Sum, Count, Max, Avg
from reportlab.lib.pagesizes import letter
from reportlab.lib import colors
from reportlab.lib.units import inch
from reportlab.platypus import SimpleDocTemplate, Paragraph, Spacer, Table, TableStyle, Image, HRFlowable
from reportlab.lib.styles import getSampleStyleSheet, ParagraphStyle
from reportlab.lib.enums import TA_CENTER, TA_LEFT, TA_RIGHT
from dashboard.models import CostRecord, UserOrganization

# ── Palette ────────────────────────────────────────────────
NAVY      = colors.HexColor('#022B51')
TEAL      = colors.HexColor('#136D90')
SLATE     = colors.HexColor('#758693')
ICE       = colors.HexColor('#F0F8FA')
WHITE     = colors.HexColor('#FBFDFD')
CHART_COLORS = ['#022B51','#136D90','#758693','#4a9bb5','#2d6a8a','#8faab8','#1a4f72','#5b8fa8','#3c7d9e','#a0bfcc']

def get_user_organization(user):
    try:
        return UserOrganization.objects.using('costs_db').get(user_id=user.id)
    except UserOrganization.DoesNotExist:
        return None


# ── Chart helpers ───────────────────────────────────────────

def make_bar_chart(labels, values, title, color_list=None, horizontal=False):
    fig, ax = plt.subplots(figsize=(6, 3.2))
    fig.patch.set_facecolor('#FBFDFD')
    ax.set_facecolor('#F0F8FA')
    clrs = (color_list or CHART_COLORS)[:len(labels)]
    if horizontal:
        ax.barh(labels, values, color=clrs)
        ax.set_xlabel('USD', fontsize=8, color='#758693')
        ax.invert_yaxis()
    else:
        ax.bar(labels, values, color=clrs)
        ax.set_ylabel('USD', fontsize=8, color='#758693')
    ax.tick_params(colors='#758693', labelsize=7)
    for spine in ax.spines.values():
        spine.set_edgecolor('#d0dce3')
    if not horizontal:
        plt.xticks(rotation=30, ha='right', fontsize=7)
    plt.tight_layout()
    buf = io.BytesIO()
    plt.savefig(buf, format='png', dpi=150, facecolor='#FBFDFD')
    plt.close(fig)
    buf.seek(0)
    return buf


def make_line_chart(labels, values, title):
    fig, ax = plt.subplots(figsize=(6.5, 3.2))
    fig.patch.set_facecolor('#FBFDFD')
    ax.set_facecolor('#F0F8FA')
    ax.plot(range(len(labels)), values, marker='o', color='#136D90',
            linewidth=2, markersize=3)
    ax.fill_between(range(len(labels)), values, alpha=0.12, color='#136D90')
    ax.set_ylabel('USD', fontsize=8, color='#758693')
    step = max(1, len(labels) // 8)
    ax.set_xticks(range(0, len(labels), step))
    ax.set_xticklabels([labels[i] for i in range(0, len(labels), step)],
                       rotation=30, ha='right', fontsize=7)
    ax.tick_params(colors='#758693')
    for spine in ax.spines.values():
        spine.set_edgecolor('#d0dce3')
    plt.tight_layout()
    buf = io.BytesIO()
    plt.savefig(buf, format='png', dpi=150, facecolor='#FBFDFD')
    plt.close(fig)
    buf.seek(0)
    return buf


def make_pie_chart(labels, values):
    fig, ax = plt.subplots(figsize=(6, 3.8))
    fig.patch.set_facecolor('#FBFDFD')
    total = sum(values)
    threshold = total * 0.02
    fl, fv, other = [], [], 0
    for l, v in zip(labels, values):
        if v >= threshold:
            fl.append(l)
            fv.append(v)
        else:
            other += v
    if other > 0:
        fl.append('Other')
        fv.append(other)
    wedges, _, autotexts = ax.pie(
        fv, labels=None, autopct='%1.1f%%',
        startangle=140, pctdistance=0.78,
        colors=CHART_COLORS[:len(fv)]
    )
    for at in autotexts:
        at.set_fontsize(7)
        at.set_color('#FBFDFD')
    ax.legend(wedges, fl, loc='center left', bbox_to_anchor=(1, 0.5), fontsize=8)
    plt.tight_layout()
    buf = io.BytesIO()
    plt.savefig(buf, format='png', dpi=150, facecolor='#FBFDFD', bbox_inches='tight')
    plt.close(fig)
    buf.seek(0)
    return buf


def make_env_bar_chart(labels, values):
    fig, ax = plt.subplots(figsize=(5, 2.8))
    fig.patch.set_facecolor('#FBFDFD')
    ax.set_facecolor('#F0F8FA')
    ax.bar(labels, values, color=CHART_COLORS[:len(labels)], width=0.5)
    ax.set_ylabel('USD', fontsize=8, color='#758693')
    ax.tick_params(colors='#758693', labelsize=8)
    for spine in ax.spines.values():
        spine.set_edgecolor('#d0dce3')
    plt.tight_layout()
    buf = io.BytesIO()
    plt.savefig(buf, format='png', dpi=150, facecolor='#FBFDFD')
    plt.close(fig)
    buf.seek(0)
    return buf


# ── Styles ──────────────────────────────────────────────────

def get_styles():
    s = getSampleStyleSheet()
    return {
        'title':    ParagraphStyle('title',    fontSize=22, alignment=TA_CENTER, spaceAfter=4,  fontName='Helvetica-Bold', textColor=NAVY),
        'subtitle': ParagraphStyle('subtitle', fontSize=10, alignment=TA_CENTER, spaceBefore=14, spaceAfter=2,  textColor=SLATE),
        'section':  ParagraphStyle('section',  fontSize=12, spaceBefore=20, spaceAfter=8, fontName='Helvetica-Bold', textColor=NAVY),
        'value': ParagraphStyle('value', fontSize=14, fontName='Helvetica-Bold', textColor=NAVY, alignment=TA_CENTER),
        'label': ParagraphStyle('label', fontSize=7, textColor=SLATE, spaceAfter=2, alignment=TA_CENTER),
        'normal':   s['Normal'],
    }


def section_divider():
    return HRFlowable(width='100%', thickness=1, color=colors.HexColor('#F0F8FA'), spaceAfter=4, spaceBefore=4)


def styled_table(data, col_widths):
    normal_style = ParagraphStyle('cell', fontSize=8, textColor=NAVY, wordWrap='CJK')
    header_style = ParagraphStyle('header', fontSize=9, textColor=WHITE, fontName='Helvetica-Bold', alignment=TA_CENTER)

    wrapped_data = []
    for i, row in enumerate(data):
        wrapped_row = []
        for cell in row:
            if isinstance(cell, str):
                style = header_style if i == 0 else normal_style
                wrapped_row.append(Paragraph(cell, style))
            else:
                wrapped_row.append(cell)
        wrapped_data.append(wrapped_row)

    t = Table(wrapped_data, colWidths=col_widths)
    t.setStyle(TableStyle([
        ('BACKGROUND',   (0, 0), (-1, 0),  NAVY),
        ('ALIGN',        (0, 0), (-1, -1), 'CENTER'),
        ('VALIGN',       (0, 0), (-1, -1), 'MIDDLE'),
        ('ROWBACKGROUNDS',(0, 1), (-1, -1), [WHITE, ICE]),
        ('GRID',         (0, 0), (-1, -1), 0.4, colors.HexColor('#d0dce3')),
        ('PADDING',      (0, 0), (-1, -1), 7),
        ('TOPPADDING',   (0, 0), (-1, 0),  9),
        ('BOTTOMPADDING',(0, 0), (-1, 0),  9),
    ]))
    return t


# ── View ────────────────────────────────────────────────────

@login_required
def generate_report(request):
    user_org = get_user_organization(request.user)
    if user_org is None:
        return redirect('dashboard')

    org = user_org.organization
    records = CostRecord.objects.using('costs_db').filter(organization=org)
    if not records.exists():
        return redirect('dashboard')

    # Aggregations
    total_cost   = records.aggregate(Sum('cost_amount'))['cost_amount__sum'] or 0
    total_records = records.count()
    zero_cost    = records.filter(cost_amount=0).count()

    by_service   = list(records.values('service_type').annotate(total=Sum('cost_amount')).order_by('-total'))
    by_resource  = list(records.values('resource_group').annotate(total=Sum('cost_amount')).order_by('-total'))
    by_region    = list(records.values('region').annotate(total=Sum('cost_amount')).order_by('-total'))
    by_date      = list(records.values('date').annotate(total=Sum('cost_amount')).order_by('date'))
    by_env       = list(records.values('env').annotate(total=Sum('cost_amount')).order_by('-total'))
    by_project   = list(records.values('project').annotate(total=Sum('cost_amount')).order_by('-total'))
    top_resources = list(records.values('raw_resource_id', 'service_type').annotate(total=Sum('cost_amount')).order_by('-total')[:5])

    date_from    = by_date[0]['date']
    date_to      = by_date[-1]['date']
    num_days     = (date_to - date_from).days + 1
    avg_daily    = round(total_cost / num_days, 2) if num_days else 0
    peak_day     = max(by_date, key=lambda x: x['total'])
    top_service  = by_service[0]['service_type'] if by_service else 'N/A'
    top_rg       = by_resource[0]['resource_group'] if by_resource else 'N/A'

    # Build PDF
    buffer = io.BytesIO()
    doc = SimpleDocTemplate(buffer, pagesize=letter,
                            rightMargin=inch * 0.75, leftMargin=inch * 0.75,
                            topMargin=inch * 0.75, bottomMargin=inch * 0.75)
    st = get_styles()
    el = []

    # ── Header ──
    el.append(Paragraph(f"{org.name}", st['title']))
    el.append(Paragraph("Cloud Cost Report", st['title']))
    el.append(Paragraph(f"Period: {date_from}  →  {date_to}", st['subtitle']))
    el.append(Spacer(1, 6))
    el.append(HRFlowable(width='100%', thickness=2, color=TEAL, spaceAfter=16))

    # ── KPI Cards ──
    kpi_data = [[
    Paragraph('TOTAL COST', st['label']),
    Paragraph('TOTAL RECORDS', st['label']),
    Paragraph('AVG DAILY COST', st['label']),
    Paragraph('IDLE RESOURCES', st['label']),
],[
    Paragraph(f"${round(total_cost, 2)}", st['value']),
    Paragraph(str(total_records), st['value']),
    Paragraph(f"${avg_daily}", st['value']),
    Paragraph(str(zero_cost), st['value']),
]]
    kpi_table = Table(kpi_data, colWidths=[1.7*inch]*4, rowHeights=[0.35*inch, 0.5*inch])
    kpi_table.setStyle(TableStyle([
        ('BACKGROUND',   (0, 0), (-1, -1), WHITE),
        ('BOX',          (0, 0), (-1, -1), 0.5, colors.HexColor('#d0dce3')),
        ('LINEBELOW',    (0, 0), (-1, 0),  1.5, TEAL),
        ('ALIGN',        (0, 0), (-1, -1), 'CENTER'),
        ('VALIGN',       (0, 0), (-1, -1), 'MIDDLE'),
        ('PADDING',      (0, 0), (-1, -1), 10),
        ('INNERGRID',    (0, 0), (-1, -1), 0.4, colors.HexColor('#d0dce3')),
    ]))
    el.append(kpi_table)
    el.append(Spacer(1, 6))

    # ── Highlights ──
    highlights_data = [[
        Paragraph('PEAK DAY', st['label']),
        Paragraph('TOP SERVICE', st['label']),
        Paragraph('TOP RESOURCE GROUP', st['label']),
    ],[
        Paragraph(f"{peak_day['date']}  (${round(float(peak_day['total']), 2)})", st['normal']),
        Paragraph(top_service, st['normal']),
        Paragraph(top_rg, st['normal']),
    ]]
    hl_table = Table(highlights_data, colWidths=[2.27*inch]*3)
    hl_table.setStyle(TableStyle([
        ('BACKGROUND',  (0, 0), (-1, -1), ICE),
        ('BOX',         (0, 0), (-1, -1), 0.5, colors.HexColor('#d0dce3')),
        ('INNERGRID',   (0, 0), (-1, -1), 0.4, colors.HexColor('#d0dce3')),
        ('ALIGN',       (0, 0), (-1, -1), 'CENTER'),
        ('PADDING',     (0, 0), (-1, -1), 10),
        ('FONTSIZE',    (0, 1), (-1, 1),  8),
        ('TEXTCOLOR',   (0, 1), (-1, 1),  NAVY),
    ]))
    el.append(hl_table)
    el.append(Spacer(1, 20))

    # ── Cost Over Time ──
    el.append(Paragraph("Cost Over Time", st['section']))
    el.append(section_divider())
    buf = make_line_chart([str(x['date']) for x in by_date], [float(x['total']) for x in by_date], 'Daily Spend')
    el.append(Image(buf, width=6.5*inch, height=3.2*inch))
    el.append(Spacer(1, 16))

    # ── Cost by Service Type ──
    el.append(Paragraph("Cost by Service Type", st['section']))
    el.append(section_divider())
    buf = make_bar_chart([x['service_type'] for x in by_service], [float(x['total']) for x in by_service], 'Cost by Service Type')
    el.append(Image(buf, width=6.5*inch, height=3.2*inch))
    el.append(Spacer(1, 8))
    svc_table_data = [['Service Type', 'Total Cost (USD)', '% of Total']] + [
        [x['service_type'], f"${round(float(x['total']), 2)}", f"{round(float(x['total'])/float(total_cost)*100, 1)}%"]
        for x in by_service
    ]
    el.append(styled_table(svc_table_data, [3.5*inch, 1.5*inch, 1.5*inch]))
    el.append(Spacer(1, 16))

    # ── Cost by Resource Group ──
    el.append(Paragraph("Cost by Resource Group", st['section']))
    el.append(section_divider())
    buf = make_bar_chart([x['resource_group'] for x in by_resource], [float(x['total']) for x in by_resource], 'Cost by Resource Group', horizontal=True)
    el.append(Image(buf, width=6.5*inch, height=3.2*inch))
    el.append(Spacer(1, 8))
    rg_table_data = [['Resource Group', 'Total Cost (USD)', '% of Total']] + [
        [x['resource_group'], f"${round(float(x['total']), 2)}", f"{round(float(x['total'])/float(total_cost)*100, 1)}%"]
        for x in by_resource
    ]
    el.append(styled_table(rg_table_data, [3.5*inch, 1.5*inch, 1.5*inch]))
    el.append(Spacer(1, 16))

    # ── Cost by Region ──
    el.append(Paragraph("Cost by Region", st['section']))
    el.append(section_divider())
    buf = make_pie_chart([x['region'] for x in by_region], [float(x['total']) for x in by_region])
    el.append(Image(buf, width=6.5*inch, height=3.5*inch))
    el.append(Spacer(1, 16))

    # ── Cost by Environment ──
    el.append(Paragraph("Cost by Environment", st['section']))
    el.append(section_divider())
    env_labels = [x['env'] or 'N/A' for x in by_env]
    env_values = [float(x['total']) for x in by_env]
    buf = make_env_bar_chart(env_labels, env_values)
    el.append(Image(buf, width=4*inch, height=2.8*inch))
    el.append(Spacer(1, 8))
    env_data = [['Environment', 'Total Cost (USD)', '% of Total']] + [
        [x['env'] or 'N/A', f"${round(float(x['total']), 2)}", f"{round(float(x['total'])/float(total_cost)*100, 1)}%"]
        for x in by_env
    ]
    el.append(styled_table(env_data, [2.5*inch, 2*inch, 2*inch]))
    el.append(Spacer(1, 16))

    # ── Cost by Project ──
    el.append(Paragraph("Cost by Project", st['section']))
    el.append(section_divider())
    project_data = [['Project', 'Total Cost (USD)', '% of Total']] + [
        [x['project'] or 'N/A', f"${round(float(x['total']), 2)}", f"{round(float(x['total'])/float(total_cost)*100, 1)}%"]
        for x in by_project
    ]
    el.append(styled_table(project_data, [2.5*inch, 2*inch, 2*inch]))
    el.append(Spacer(1, 16))

    # ── Top 5 Most Expensive Resources ──
    el.append(Paragraph("Top 5 Most Expensive Resources", st['section']))
    el.append(section_divider())
    top_data = [['Resource ID', 'Service', 'Total Cost (USD)']] + [
        [
            x['raw_resource_id'].split('/')[-1] if x['raw_resource_id'] else 'N/A',
            x['service_type'],
            f"${round(float(x['total']), 2)}"
        ]
        for x in top_resources
    ]
    el.append(styled_table(top_data, [3.5*inch, 2*inch, 1*inch]))

    # Build
    doc.build(el)
    buffer.seek(0)
    response = HttpResponse(buffer, content_type='application/pdf')
    response['Content-Disposition'] = f'attachment; filename="{org.name}_cost_report.pdf"'
    return response