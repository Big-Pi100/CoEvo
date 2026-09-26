"""Generate WeChat cover images (2.35:1 + 1:1) for each article"""
from PIL import Image, ImageDraw, ImageFont
import os

OUT = "E:/CoEvo/docs/multiplatform"
os.makedirs(f"{OUT}/article-ai-education", exist_ok=True)
os.makedirs(f"{OUT}/article-fsrs-vs-ebbinghaus", exist_ok=True)
os.makedirs(f"{OUT}/article-testing-effect", exist_ok=True)
os.makedirs(f"{OUT}/article-sleep-memory", exist_ok=True)
os.makedirs(f"{OUT}/article-growth-mindset", exist_ok=True)

# Font setup
try:
    title_font = ImageFont.truetype("C:/Windows/Fonts/msyhbd.ttc", 48)
    subtitle_font = ImageFont.truetype("C:/Windows/Fonts/msyh.ttc", 24)
    num_font = ImageFont.truetype("C:/Windows/Fonts/msyhbd.ttc", 64)
    num_font_large = ImageFont.truetype("C:/Windows/Fonts/msyhbd.ttc", 80)
    label_font = ImageFont.truetype("C:/Windows/Fonts/msyh.ttc", 20)
except:
    title_font = ImageFont.load_default()
    subtitle_font = title_font
    num_font = title_font
    num_font_large = title_font
    label_font = title_font

def draw_multiline_text(draw, text, pos, font, color, max_width):
    """Draw text with manual wrapping for newlines"""
    lines = text.split('\n')
    y = pos[1]
    for line in lines:
        draw.text((pos[0], y), line, font=font, fill=color)
        y += 60
    return len(lines)

def make_wechat_pair(article_id, title, data_num, data_label, bg_color="#2C3E50", 
                     accent_color="#3498DB", show_num=True):
    """Generate 2.35:1 (wide) and 1:1 (square) cover images
    
    封面包含：
    - CoEvo 品牌标识
    - 核心数据（大字号）
    - 文章标题（完整显示）
    """
    
    # ── 2.35:1 — 1200x511 ──
    w_wide, h_wide = 1200, 511
    
    img = Image.new('RGB', (w_wide, h_wide), bg_color)
    draw = ImageDraw.Draw(img)
    
    # CoEvo label
    draw.text((36, 18), "CoEvo AI特级教师", font=subtitle_font, fill="#B0BEC5")
    
    # Big data number
    num_font_96 = ImageFont.truetype("C:/Windows/Fonts/msyhbd.ttc", 96) if os.path.exists("C:/Windows/Fonts/msyhbd.ttc") else num_font_large
    if show_num and data_num:
        draw.text((36, 60), data_num, font=num_font_96, fill=accent_color)
        draw.text((36, 170), data_label, font=label_font, fill="#B0BEC5")
        title_y = 210
    else:
        title_y = 80
    
    # Article title
    lines = title.split('\n')
    for i, line in enumerate(lines):
        draw.text((36, title_y + i * 55), line, font=title_font, fill="white")

    img.save(f"{OUT}/{article_id}/wechat-2351.png")
    
    # ── 1:1 — 800x800 ──
    img2 = Image.new('RGB', (800, 800), bg_color)
    draw2 = ImageDraw.Draw(img2)
    
    draw2.text((36, 18), "CoEvo AI特级教师", font=subtitle_font, fill="#B0BEC5")
    
    if show_num and data_num:
        draw2.text((36, 90), data_num, font=num_font_96, fill=accent_color)
        draw2.text((36, 200), data_label, font=label_font, fill="#B0BEC5")
        title_y2 = 240
    else:
        title_y2 = 100
    
    lines = title.split('\n')
    for i, line in enumerate(lines):
        draw2.text((36, title_y2 + i * 55), line, font=title_font, fill="white")

    img2.save(f"{OUT}/{article_id}/wechat-1to1.png")
    
    print(f"  ✓ {article_id}")


# Generate covers for each article
articles = [
    ("article-ai-education", "AI到底能不能\n帮孩子提分？", "+18%/-20%", "作业涨  考试跌", "#1A237E", "#4FC3F7"),
    ("article-fsrs-vs-ebbinghaus", "FSRS vs\n艾宾浩斯遗忘曲线", "2~3倍", "效率提升", "#004D40", "#4DB6AC"),
    ("article-testing-effect", "为什么考考考\n才是最好的学习方法？", "80%", "1周后记住", "#4A148C", "#CE93D8"),
    ("article-sleep-memory", "睡觉就是学习\n效率翻倍的秘密", "85%", "8小时后记忆保持", "#E65100", "#FFB74D"),
    ("article-growth-mindset", "成长型思维vs\n固定型思维", "+30%", "成绩差距", "#1B5E20", "#81C784"),
]

print("Generating WeChat cover images...")
for aid, title, num, label, bg, accent in articles:
    bg_rgb = tuple(int(bg[i:i+2], 16) for i in (1, 3, 5))
    ac_rgb = tuple(int(accent[i:i+2], 16) for i in (1, 3, 5))
    make_wechat_pair(aid, title, num, label, bg_rgb, ac_rgb, show_num=True)

print("Done!")
