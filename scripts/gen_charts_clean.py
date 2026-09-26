"""Generate clean charts for CoEvo blog → social media"""
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
import os

OUT = "E:/CoEvo/docs/multiplatform/demo/images"
os.makedirs(OUT, exist_ok=True)

# Font setup - simple and working
plt.rcParams['font.family'] = 'Microsoft YaHei'
plt.rcParams['axes.unicode_minus'] = False

# Color palette (clean, neutral, readable)
BG = '#FAFAFA'
RED = '#E74C3C'
GREEN = '#27AE60'
BLUE = '#3498DB'
TEAL = '#1ABC9C'
AMBER = '#F39C12'
GRAY = '#95A5A6'
DARK = '#2C3E50'
LIGHT = '#ECF0F1'

def make_fig(w=6.5, h=4):
    fig, ax = plt.subplots(figsize=(w, h), facecolor=BG)
    ax.set_facecolor(BG)
    ax.spines['top'].set_visible(False)
    ax.spines['right'].set_visible(False)
    ax.spines['left'].set_color('#DDD')
    ax.spines['bottom'].set_color('#DDD')
    ax.tick_params(colors='#888', labelsize=11)
    ax.yaxis.grid(True, alpha=0.15, color='#999')
    ax.set_axisbelow(True)
    return fig, ax

# ── Chart 1: 成绩变化 ──
fig, ax = make_fig()
cats = ['作业成绩', '闭卷考试', '中考成绩', '高考成绩']
vals = [18, -20, -24, -18]
clrs = [GREEN, RED, RED, RED]
bars = ax.bar(cats, vals, color=clrs, width=0.5, edgecolor='white', linewidth=1.5)
for b, v in zip(bars, vals):
    y = b.get_height()
    off = 2 if v > 0 else -4
    ax.text(b.get_x()+b.get_width()/2, y+off, f'{v:+d}%', ha='center', va='bottom' if v>0 else 'top',
            fontsize=14, fontweight='bold', color=RED if v<0 else GREEN)
ax.set_ylabel('变化幅度', fontsize=11, color='#666')
ax.set_title('用AI学习后，学生的成绩发生了什么变化？', fontsize=14, fontweight='bold', color=DARK, pad=15)
ax.text(0.98, 0.02, '数据来源：CEPR DP21577', transform=ax.transAxes, fontsize=9, color='#999', ha='right', va='bottom')
plt.tight_layout()
fig.savefig(f"{OUT}/chart1-score-change.png", dpi=250, bbox_inches='tight', facecolor=BG)
plt.close()
print("✓ chart1")

# ── Chart 2: 学生分组影响 ──
fig, ax = make_fig()
groups = ['成绩最好\n(前25%)', '中等学生', '成绩靠后\n(后25%)']
drops = [24, 18, 16]
clrs2 = [RED, AMBER, GREEN]
bars = ax.barh(groups, drops, color=clrs2, height=0.45, edgecolor='white', linewidth=1.5)
for b, v, c in zip(bars, drops, clrs2):
    ax.text(b.get_width()+0.3, b.get_y()+b.get_height()/2, f'考试下降 {v}%', ha='left', va='center', fontsize=12, fontweight='bold', color=DARK)
ax.set_xlim(0, max(drops)+10)
ax.set_title('不同水平学生受AI影响程度', fontsize=14, fontweight='bold', color=DARK, pad=15)
ax.set_xticks([])
ax.spines['bottom'].set_visible(False)
ax.text(0.98, 0.02, '数据来源：CEPR DP21577', transform=ax.transAxes, fontsize=9, color='#999', ha='right', va='bottom')
plt.tight_layout()
fig.savefig(f"{OUT}/chart2-student-impact.png", dpi=250, bbox_inches='tight', facecolor=BG)
plt.close()
print("✓ chart2")

# ── Chart 3: 测试效应 ──
fig, ax = make_fig(6, 3.8)
methods = ['反复阅读\n4遍', '阅读+\n回忆2轮', '阅读+\n反复测试']
scores = [50, 70, 80]
clrs3 = [GRAY, BLUE, TEAL]
bars = ax.bar(methods, scores, color=clrs3, width=0.5, edgecolor='white', linewidth=1.5)
for b, v in zip(bars, scores):
    ax.text(b.get_x()+b.get_width()/2, b.get_height()+1.5, f'{v}%', ha='center', fontsize=14, fontweight='bold', color=DARK)
ax.set_ylim(0, 100)
ax.set_ylabel('1周后记忆保持率', fontsize=11, color='#666')
ax.set_title('哪种学习方法效果最好？', fontsize=14, fontweight='bold', color=DARK, pad=15)
ax.text(0.98, 0.02, '来源：Karpicke & Roediger (2006)', transform=ax.transAxes, fontsize=9, color='#999', ha='right', va='bottom')
plt.tight_layout()
fig.savefig(f"{OUT}/chart3-testing-effect.png", dpi=250, bbox_inches='tight', facecolor=BG)
plt.close()
print("✓ chart3")

# ── Chart 4: FSRS vs 艾宾浩斯 ──
fig, ax = make_fig(7, 4.2)
import numpy as np
methods = ['不复习', '考前突击', '艾宾浩斯间隔', 'FSRS优化']
m1 = [20, 40, 70, 90]
y1 = [5, 10, 40, 75]
x = np.arange(len(methods))
w = 0.3
b1 = ax.bar(x-w/2, m1, w, label='1个月后', color=BLUE, edgecolor='white', linewidth=1)
b2 = ax.bar(x+w/2, y1, w, label='1年后', color=TEAL, edgecolor='white', linewidth=1)
for b, v in zip(b1, m1):
    ax.text(b.get_x()+b.get_width()/2, b.get_height()+1, f'{v}%', ha='center', fontsize=10, fontweight='bold', color=BLUE)
for b, v in zip(b2, y1):
    ax.text(b.get_x()+b.get_width()/2, b.get_height()+1, f'{v}%', ha='center', fontsize=10, fontweight='bold', color=TEAL)
ax.set_xticks(x)
ax.set_xticklabels(methods, fontsize=11)
ax.set_ylabel('记忆保持率 (%)', fontsize=11, color='#666')
ax.set_title('不同复习方法的长期记忆效果', fontsize=14, fontweight='bold', color=DARK, pad=15)
ax.legend(fontsize=11, frameon=True, facecolor='white', edgecolor='#DDD')
plt.tight_layout()
fig.savefig(f"{OUT}/chart4-fsrs-vs.png", dpi=250, bbox_inches='tight', facecolor=BG)
plt.close()
print("✓ chart4")

# ── Chart 5: 睡眠记忆 ──
fig, ax = make_fig(6, 3.8)
conds = ['学完直接\n睡8小时', '不睡\n16小时后', '只睡4小时']
vals5 = [85, 45, 65]
clrs5 = [GREEN, RED, AMBER]
bars = ax.bar(conds, vals5, color=clrs5, width=0.45, edgecolor='white', linewidth=1.5)
for b, v in zip(bars, vals5):
    ax.text(b.get_x()+b.get_width()/2, b.get_height()+1.5, f'{v}%', ha='center', fontsize=14, fontweight='bold', color=DARK)
ax.set_ylim(0, 100)
ax.set_ylabel('8小时后记忆保持 (%)', fontsize=11, color='#666')
ax.set_title('睡眠对记忆巩固的影响', fontsize=14, fontweight='bold', color=DARK, pad=15)
ax.text(0.98, 0.02, '来源：Walker & Stickgold (2006)', transform=ax.transAxes, fontsize=9, color='#999', ha='right', va='bottom')
plt.tight_layout()
fig.savefig(f"{OUT}/chart5-sleep-memory.png", dpi=250, bbox_inches='tight', facecolor=BG)
plt.close()
print("✓ chart5")

print(f"\nDone! All charts in {OUT}/")
