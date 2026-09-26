#!/usr/bin/env python3
"""
咪蒙文章爬虫 — 泡泡哥网站文章采集器
======================================
爬取 paopaoge.com 上咪蒙所有文章，保存为 Markdown 格式，
并生成 index.json 元数据文件。

目标页面：
  - 总览页：https://www.paopaoge.com/category-98.html（咪蒙全集）
  - 各年份分类页：
      99 → 2015, 100 → 2016, 101 → 2017, 102 → 2018, 103 → 2019
  - 单篇文章：https://www.paopaoge.com/post/{id}.html

输出目录：E:/CoEvo/data/mimeng-articles/
输出格式：YYYY-MM-DD-标题slug.md
"""

import os
import re
import json
import time
import random
import logging
from datetime import datetime
from typing import Optional

import requests
from bs4 import BeautifulSoup

# ── 配置 ──────────────────────────────────────────────────────────
CATEGORY_YEARS = {
    99: 2015,
    100: 2016,
    101: 2017,
    102: 2018,
    103: 2019,
}

OUTPUT_DIR = r"E:\CoEvo\data\mimeng-articles"
ERROR_LOG = os.path.join(os.path.dirname(OUTPUT_DIR), "error.log")
INDEX_PATH = os.path.join(OUTPUT_DIR, "index.json")

BASE_URL = "https://www.paopaoge.com"
CATEGORY_URL_TPL = BASE_URL + "/category-{}.html"

REQUEST_TIMEOUT = 15  # seconds
MIN_DELAY = 0.5
MAX_DELAY = 1.0

HEADERS = {
    "User-Agent": (
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
        "AppleWebKit/537.36 (KHTML, like Gecko) "
        "Chrome/120.0.0.0 Safari/537.36"
    )
}

# ── 日志配置 ──────────────────────────────────────────────────────
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
logger = logging.getLogger("mimeng_crawler")


def setup_error_logger() -> logging.Logger:
    """创建独立的 error.log 记录器"""
    err_logger = logging.getLogger("error_logger")
    err_logger.setLevel(logging.ERROR)
    # 避免重复添加 handler
    if not err_logger.handlers:
        fh = logging.FileHandler(ERROR_LOG, mode="w", encoding="utf-8")
        fh.setLevel(logging.ERROR)
        fmt = logging.Formatter("%(asctime)s [%(levelname)s] %(message)s", datefmt="%Y-%m-%d %H:%M:%S")
        fh.setFormatter(fmt)
        err_logger.addHandler(fh)
    return err_logger


error_logger = setup_error_logger()


# ── 工具函数 ──────────────────────────────────────────────────────

def slugify(title: str) -> str:
    """将标题转为文件系统友好的 slug（保留中文）"""
    # 替换非法文件名字符
    cleaned = re.sub(r'[\\/:*?"<>|]', '', title)
    # 替换空白为连字符
    cleaned = re.sub(r'\s+', '-', cleaned.strip())
    # 如果太长则截断
    if len(cleaned) > 80:
        cleaned = cleaned[:80]
    # 去掉首尾连字符
    cleaned = cleaned.strip('-')
    return cleaned if cleaned else "untitled"


def safe_filename(date_str: str, title: str) -> str:
    """生成安全的文件名：YYYY-MM-DD-标题slug.md"""
    slug = slugify(title)
    return f"{date_str}-{slug}.md"


def extract_article_id(url: str) -> Optional[int]:
    """从 URL 中提取文章数字 ID"""
    m = re.search(r'/post/(\d+)\.html', url)
    if m:
        return int(m.group(1))
    return None


def parse_date_from_category(date_text: str, year: int) -> Optional[str]:
    """从分类页的日期文本（如 '12-18'）和年份，解析为 YYYY-MM-DD"""
    date_text = date_text.strip()
    # 匹配 MM-DD 格式
    m = re.match(r'(\d{1,2})-(\d{1,2})', date_text)
    if m:
        month, day = int(m.group(1)), int(m.group(2))
        return f"{year}-{month:02d}-{day:02d}"
    return None


def html_to_markdown(html_content: str) -> str:
    """将 HTML 片段转换为纯文本/Markdown"""
    soup = BeautifulSoup(html_content, 'html.parser')

    # 移除不需要的元素
    for tag in soup(['script', 'style', 'iframe', 'noscript']):
        tag.decompose()

    # 处理图片 —— 保留图片链接
    for img in soup.find_all('img'):
        src = img.get('src', '')
        alt = img.get('alt', '')
        if src:
            # 构造相对/绝对链接
            if src.startswith('//'):
                src = 'https:' + src
            elif src.startswith('/'):
                src = BASE_URL + src
            if alt:
                img_md = f"![{alt}]({src})"
            else:
                img_md = f"![]({src})"
            img.replace_with(soup.new_string(f"\n{img_md}\n"))

    # 处理链接
    for a_tag in soup.find_all('a'):
        href = a_tag.get('href', '')
        text = a_tag.get_text(strip=True)
        if href and text:
            if href.startswith('//'):
                href = 'https:' + href
            elif href.startswith('/'):
                href = BASE_URL + href
            a_md = f"[{text}]({href})"
            a_tag.replace_with(soup.new_string(a_md))

    # 处理加粗/斜体
    for b_tag in soup.find_all(['strong', 'b']):
        text = b_tag.get_text(strip=True)
        if text:
            b_tag.replace_with(soup.new_string(f" **{text}** "))

    for i_tag in soup.find_all(['em', 'i']):
        text = i_tag.get_text(strip=True)
        if text:
            i_tag.replace_with(soup.new_string(f" *{text}* "))

    # 处理段落
    for p_tag in soup.find_all('p'):
        p_text = p_tag.get_text(strip=True)
        if p_text:
            p_tag.replace_with(soup.new_string(f"\n\n{p_text}\n\n"))

    # 处理 blockquote
    for bq_tag in soup.find_all('blockquote'):
        bq_text = bq_tag.get_text(strip=True)
        if bq_text:
            bq_tag.replace_with(soup.new_string(f"\n\n> {bq_text}\n\n"))

    # 处理换行
    for br_tag in soup.find_all('br'):
        br_tag.replace_with('\n')

    # 处理标题 (h2-h6)
    for level in range(2, 7):
        for h_tag in soup.find_all(f'h{level}'):
            h_text = h_tag.get_text(strip=True)
            if h_text:
                prefix = '#' * level
                h_tag.replace_with(soup.new_string(f"\n\n{prefix} {h_text}\n\n"))

    # 处理水平线
    for hr_tag in soup.find_all('hr'):
        hr_tag.replace_with(soup.new_string('\n\n---\n\n'))

    # 处理列表
    for ul_tag in soup.find_all('ul'):
        items = []
        for li in ul_tag.find_all('li'):
            li_text = li.get_text(strip=True)
            if li_text:
                items.append(f"- {li_text}")
        if items:
            ul_tag.replace_with(soup.new_string('\n\n' + '\n'.join(items) + '\n\n'))

    for ol_tag in soup.find_all('ol'):
        items = []
        for i, li in enumerate(ol_tag.find_all('li'), 1):
            li_text = li.get_text(strip=True)
            if li_text:
                items.append(f"{i}. {li_text}")
        if items:
            ol_tag.replace_with(soup.new_string('\n\n' + '\n'.join(items) + '\n\n'))

    # 获取纯文本
    text = soup.get_text()

    # 清理多余空白
    lines = text.split('\n')
    cleaned_lines = []
    for line in lines:
        line = line.strip()
        if line:
            cleaned_lines.append(line)

    text = '\n\n'.join(cleaned_lines)

    # 进一步清理：将超过2个连续的换行减少为2个
    text = re.sub(r'\n{3,}', '\n\n', text)

    return text.strip()


def fetch_page(url: str) -> Optional[str]:
    """获取页面 HTML，失败返回 None"""
    try:
        resp = requests.get(url, headers=HEADERS, timeout=REQUEST_TIMEOUT)
        resp.encoding = 'utf-8'
        if resp.status_code == 200:
            return resp.text
        else:
            logger.warning("HTTP %d for %s", resp.status_code, url)
            return None
    except requests.RequestException as e:
        logger.warning("Request failed for %s: %s", url, e)
        return None


# ── 核心爬取逻辑 ──────────────────────────────────────────────────

def scrape_category(category_id: int, year: int) -> list[dict]:
    """
    爬取单个分类页，提取文章列表。
    返回: [{"id": int, "title": str, "date": "YYYY-MM-DD", "url": str}, ...]
    """
    url = CATEGORY_URL_TPL.format(category_id)
    logger.info("正在爬取分类页：%s（年份 %d）", url, year)

    html = fetch_page(url)
    if not html:
        logger.error("无法获取分类页：%s", url)
        return []

    soup = BeautifulSoup(html, 'html.parser')
    articles = []

    # 查找文章列表：<ul class="list-a"><li><span>MM-DD</span><a ...>title</a></li></ul>
    ul = soup.find('ul', class_='list-a')
    if not ul:
        logger.warning("分类页 %s 中未找到 <ul class='list-a'>", url)
        return []

    for li in ul.find_all('li', recursive=False):
        span = li.find('span')
        a_tag = li.find('a', href=re.compile(r'/post/\d+\.html'))

        if not a_tag:
            continue

        href = a_tag.get('href', '')
        title = a_tag.get_text(strip=True)
        if not title:
            title = a_tag.get('title', '')

        article_id = extract_article_id(href)
        if article_id is None:
            continue

        # 解析日期
        date_str = None
        if span:
            date_str = parse_date_from_category(span.get_text(strip=True), year)

        if not date_str:
            # 如果解析失败，尝试从 title 属性提取
            date_str = f"{year}-01-01"  # fallback

        full_url = href if href.startswith('http') else BASE_URL + href

        articles.append({
            "id": article_id,
            "title": title,
            "date": date_str,
            "url": full_url,
            "year": year,
        })

    logger.info("分类页 %d（%d）找到 %d 篇文章", category_id, year, len(articles))
    return articles


def scrape_article(article_info: dict) -> Optional[str]:
    """
    爬取单篇文章内容，返回 Markdown 格式文本，失败返回 None。
    """
    url = article_info["url"]
    title = article_info["title"]
    date = article_info["date"]

    logger.info("正在爬取文章：%s (%s)", title, date)

    html = fetch_page(url)
    if not html:
        return None

    soup = BeautifulSoup(html, 'html.parser')

    # 提取标题（优先从页面 <h1> 获取，保留分类页的标题作为 fallback）
    h1 = soup.find('h1')
    page_title = h1.get_text(strip=True) if h1 else title

    # 提取正文内容
    # <div class="content" id="content{id}">
    content_div = soup.find('div', class_='content')
    if not content_div:
        # 尝试通过 id 查找
        content_div = soup.find('div', id=lambda x: x and x.startswith('content'))
    if not content_div:
        # 最后尝试：找 article 标签或 main 标签
        content_div = soup.find('article') or soup.find('main')

    if not content_div:
        logger.warning("文章 %s 找不到正文内容容器", url)
        return None

    # 转换为 Markdown
    body_html = str(content_div)
    body_md = html_to_markdown(body_html)

    # 组装最终 Markdown
    md_content = (
        f"# {page_title}\n\n"
        f"> 来源：[paopaoge]({url})\n"
        f"> 日期：{date}\n\n"
        f"{body_md}\n"
    )

    return md_content


def save_article(article_info: dict, md_content: str) -> Optional[str]:
    """
    保存文章为 Markdown 文件。
    返回文件路径（相对路径），失败返回 None。
    """
    date_str = article_info["date"]
    title = article_info["title"]
    article_id = article_info["id"]

    filename = safe_filename(date_str, title)
    filepath = os.path.join(OUTPUT_DIR, filename)

    try:
        with open(filepath, 'w', encoding='utf-8') as f:
            f.write(md_content)
        logger.info("已保存：%s", filename)
        # 返回相对路径
        return f"data/mimeng-articles/{filename}"
    except OSError as e:
        logger.error("保存文件失败 %s: %s", filename, e)
        return None


def crawl_all() -> list[dict]:
    """
    主爬取流程：
    1. 遍历所有分类页获取文章列表
    2. 逐篇爬取正文并保存
    3. 生成 index.json
    返回所有文章的元数据列表（含文件路径）。
    """
    os.makedirs(OUTPUT_DIR, exist_ok=True)

    # 第一步：收集所有文章元数据
    all_articles = []
    for cat_id, year in sorted(CATEGORY_YEARS.items()):
        articles = scrape_category(cat_id, year)
        all_articles.extend(articles)
        time.sleep(random.uniform(MIN_DELAY, MAX_DELAY))

    # 按日期排序
    all_articles.sort(key=lambda a: a["date"])

    logger.info("共发现 %d 篇文章", len(all_articles))

    # 第二步：逐篇爬取并保存
    success_count = 0
    fail_count = 0
    result_articles = []

    for idx, article in enumerate(all_articles, 1):
        logger.info("[%d/%d] 处理：%s", idx, len(all_articles), article["title"])

        md_content = scrape_article(article)
        if md_content is None:
            fail_count += 1
            error_msg = f"爬取失败: {article['url']} (ID: {article['id']}, 标题: {article['title']})"
            logger.error(error_msg)
            error_logger.error(error_msg)
            continue

        file_path = save_article(article, md_content)
        if file_path:
            success_count += 1
            result_articles.append({
                "id": article["id"],
                "title": article["title"],
                "date": article["date"],
                "year": article["year"],
                "url": article["url"],
                "file": file_path,
            })
        else:
            fail_count += 1

        # 礼貌延迟
        time.sleep(random.uniform(MIN_DELAY, MAX_DELAY))

    # 第三步：生成 index.json
    with open(INDEX_PATH, 'w', encoding='utf-8') as f:
        json.dump(result_articles, f, ensure_ascii=False, indent=2)

    logger.info("=" * 50)
    logger.info("爬取完成！")
    logger.info("总篇数：%d", len(all_articles))
    logger.info("成功篇数：%d", success_count)
    logger.info("失败篇数：%d", fail_count)
    logger.info("=" * 50)

    return result_articles


def verify_results(result_articles: list[dict]) -> bool:
    """
    验证爬取结果：
    - index.json 条目数 = 实际文件数
    - 检查文件是否存在
    """
    logger.info("正在验证结果...")

    # 检查 index.json 条目
    index_count = len(result_articles)
    logger.info("index.json 条目数：%d", index_count)

    # 检查实际文件
    actual_files = [f for f in os.listdir(OUTPUT_DIR) if f.endswith('.md')]
    actual_count = len(actual_files)
    logger.info("实际 Markdown 文件数：%d", actual_count)

    # 比对
    if index_count == actual_count:
        logger.info("✅ 条目数与文件数一致")
    else:
        logger.warning("⚠️ 条目数 (%d) 与文件数 (%d) 不一致", index_count, actual_count)

    # 检查每个文件是否存在
    missing = []
    for art in result_articles:
        rel_path = art["file"]
        abs_path = os.path.join(OUTPUT_DIR, os.path.basename(rel_path))
        if not os.path.exists(abs_path):
            missing.append(art["id"])

    if missing:
        logger.warning("⚠️ 以下文章文件缺失: %s", missing)
    else:
        logger.info("✅ 所有文件均存在")

    # 检查 index.json 自身
    if os.path.exists(INDEX_PATH):
        with open(INDEX_PATH, 'r', encoding='utf-8') as f:
            reloaded = json.load(f)
        if len(reloaded) == index_count:
            logger.info("✅ index.json 可正确读取，条目一致")
        else:
            logger.warning("⚠️ index.json 读取后条目数不匹配")
    else:
        logger.warning("⚠️ index.json 文件不存在")

    return index_count == actual_count and len(missing) == 0


# ── 入口 ──────────────────────────────────────────────────────────

def main():
    logger.info("咪蒙文章爬虫启动")
    logger.info("输出目录：%s", OUTPUT_DIR)
    logger.info("")

    result_articles = crawl_all()

    if result_articles:
        verify_results(result_articles)
    else:
        logger.warning("未爬取到任何文章")

    logger.info("")
    logger.info("爬虫结束。错误日志：%s", ERROR_LOG)


if __name__ == '__main__':
    main()
