import requests
from bs4 import BeautifulSoup
import re
from typing import Dict, List
from datetime import datetime
from paddleocr import PaddleOCR
import os
from PIL import Image
from io import BytesIO
import numpy

class AdCompetitionSpider:
    """大广赛爬虫类"""
    def __init__(self):
        self.base_url = "https://www.sun-ada.net"
        self.headers = {
            'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36'
        }
        # 初始化 OCR
        self.ocr = PaddleOCR(use_angle_cls=True, lang="ch")

    def get_text_from_image(self, image_url: str) -> str:
        """从图片中提取文字"""
        try:
            print(f"正在处理图片: {image_url}")
            # 下载图片
            response = requests.get(image_url, headers=self.headers)
            if response.status_code != 200:
                print(f"下载图片失败: {response.status_code}")
                return ""

            # 将图片内容转换为PIL Image对象
            image = Image.open(BytesIO(response.content))
            
            # 使用OCR识别文字
            result = self.ocr.ocr(numpy.array(image), cls=True)
            
            # 提取所有识别出的文字
            text_list = []
            if result:
                for line in result:
                    for word_info in line:
                        text_list.append(word_info[1][0])  # 提取识别出的文字
            
            # 合并所有文字
            full_text = "\n".join(text_list)
            print(f"识别出的文字:\n{full_text[:200]}...")  # 打印前200个字符
            
            return full_text

        except Exception as e:
            print(f"图片处理失败: {str(e)}")
            return ""

    def parse_news_content(self, url: str) -> Dict:
        """解析新闻内容（包括图片中的文字）"""
        try:
            print(f"正在解析页面: {url}")
            response = requests.get(url, headers=self.headers)
            response.encoding = 'utf-8'
            soup = BeautifulSoup(response.text, 'html.parser')
            
            # 查找图片
            img_tags = soup.find_all('img')
            content_text = ""
            
            for img in img_tags:
                img_url = img.get('src', '')
                if img_url:
                    if not img_url.startswith('http'):
                        img_url = f"{self.base_url}/{img_url.lstrip('/')}"
                    
                    # 获取图片中的文字
                    img_text = self.get_text_from_image(img_url)
                    if img_text:
                        content_text += f"\n{img_text}"
            
            # 日期匹配模式
            date_patterns = [
                r"报名日期[：:]\s*([\d年月日\s至]+)",
                r"报名时间[：:]\s*([\d年月日\s至]+)",
                r"(\d{4}年\d{1,2}月\d{1,2}日)[至到]\s*(\d{4}年\d{1,2}月\d{1,2}日)",
                r"(\d{4}\.\d{1,2}\.\d{1,2})[至到]\s*(\d{4}\.\d{1,2}\.\d{1,2})",
                r"(\d{4}年\d{1,2}月\d{1,2}日)\s*[起至到]\s*(\d{4}年\d{1,2}月\d{1,2}日)\s*[结束]?",
                r"(\d{4}\.\d{1,2}\.\d{1,2})\s*[起至到]\s*(\d{4}\.\d{1,2}\.\d{1,2})\s*[结束]?"
            ]
            
            # 参赛要求匹配模式
            requirements_patterns = [
                r"参赛对象[：:]\s*([^。\n]+)",
                r"参赛资格[：:]\s*([^。\n]+)",
                r"参赛人员[：:]\s*([^。\n]+)",
                r"参赛范围[：:]\s*([^。\n]+)"
            ]
            
            # 主办方匹配模式
            organizer_patterns = [
                r"主办[：:]\s*([^。\n]+)",
                r"主办单位[：:]\s*([^。\n]+)",
                r"主办方[：:]\s*([^。\n]+)"
            ]
            
            # 承办方匹配模式
            undertaker_patterns = [
                r"承办[：:]\s*([^。\n]+)",
                r"承办单位[：:]\s*([^。\n]+)",
                r"承办方[：:]\s*([^。\n]+)"
            ]
            
            # 尝试匹配日期
            date_info = None
            for pattern in date_patterns:
                match = re.search(pattern, content_text)
                if match:
                    if len(match.groups()) == 1:
                        date_info = match.group(1)
                    elif len(match.groups()) == 2:
                        date_info = f"{match.group(1)}至{match.group(2)}"
                    break
            
            # 尝试匹配其他信息
            requirements = None
            for pattern in requirements_patterns:
                match = re.search(pattern, content_text)
                if match:
                    requirements = match.group(1)
                    break
                    
            organizer = None
            for pattern in organizer_patterns:
                match = re.search(pattern, content_text)
                if match:
                    organizer = match.group(1)
                    break
                    
            undertaker = None
            for pattern in undertaker_patterns:
                match = re.search(pattern, content_text)
                if match:
                    undertaker = match.group(1)
                    break

            return {
                'content': content_text,
                'date_info': date_info if date_info else "未找到报名日期",
                'requirements': requirements if requirements else "未找到参赛要求",
                'organizer': organizer if organizer else "未找到主办方",
                'undertaker': undertaker if undertaker else "未找到承办方"
            }
        except Exception as e:
            print(f"解析页面失败: {str(e)}")
            return None

    def fetch_news_urls(self) -> List[Dict]:
        """爬取所有新闻链接"""
        try:
            print(f"开始访问新闻页: {self.base_url}/home/newss.html")
            response = requests.get(f"{self.base_url}/home/newss.html", headers=self.headers)
            response.encoding = 'utf-8'
            
            soup = BeautifulSoup(response.text, 'html.parser')
            news_list = soup.find('ul', class_='list_news')
            if not news_list:
                print("未找到新闻列表")
                return []
                
            news_items = news_list.find_all('li')
            print(f"\n找到 {len(news_items)} 条新闻")
            
            news_urls = []
            competition_keywords = ["大广赛", "征集", "参赛", "比赛", "竞赛", "作品"]
            
            for index, item in enumerate(news_items, 1):
                link = item.find('a')
                if not link:
                    continue
                
                title_elem = link.find('h3')
                if not title_elem:
                    continue
                    
                title = title_elem.get_text(strip=True)
                date_elem = link.find('em')
                date = date_elem.get_text(strip=True) if date_elem else ""
                
                href = link.get('href', '')
                if href.startswith('http'):
                    url = href
                elif href.startswith('/'):
                    url = f"{self.base_url}{href}"
                else:
                    url = f"{self.base_url}/{href}"
                
                is_competition = any(keyword in title for keyword in competition_keywords)
                
                if is_competition:
                    # 解析新闻内容（包括图片中的文字）
                    content_info = self.parse_news_content(url)
                    if content_info:
                        news_info = {
                            'index': index,
                            'title': title,
                            'date': date,
                            'url': url,
                            'is_competition': True,
                            'content': content_info['content'],
                            'date_info': content_info['date_info'],
                            'requirements': content_info['requirements'],
                            'organizer': content_info['organizer'],
                            'undertaker': content_info['undertaker']
                        }
                    else:
                        news_info = {
                            'index': index,
                            'title': title,
                            'date': date,
                            'url': url,
                            'is_competition': True
                        }
                else:
                    news_info = {
                        'index': index,
                        'title': title,
                        'date': date,
                        'url': url,
                        'is_competition': False
                    }
                
                news_urls.append(news_info)
            
            return news_urls
            
        except Exception as e:
            print(f"爬取失败: {str(e)}")
            import traceback
            print(traceback.format_exc())
            return []

def main():
    spider = AdCompetitionSpider()
    print("开始测试爬虫...")
    news_urls = spider.fetch_news_urls()
    
    if news_urls:
        print("\n所有新闻列表:")
        print("-" * 50)
        
        competition_news = [news for news in news_urls if news['is_competition']]
        other_news = [news for news in news_urls if not news['is_competition']]
        
        print("\n== 比赛相关新闻 ==")
        for news in competition_news:
            print(f"{news['index']}. {news['title']}")
            print(f"   发布日期: {news['date']}")
            print(f"   链接: {news['url']}")
            if 'content' in news:
                print(f"   报名日期: {news.get('date_info', '未找到')}")
                print(f"   参赛要求: {news.get('requirements', '未找到')}")
                print(f"   主办方: {news.get('organizer', '未找到')}")
                print(f"   承办方: {news.get('undertaker', '未找到')}")
            print("-" * 50)
            
        print("\n== 其他新闻 ==")
        for news in other_news:
            print(f"{news['index']}. {news['title']}")
            print(f"   发布日期: {news['date']}")
            print(f"   链接: {news['url']}")
            print("-" * 50)
            
        print(f"\n总计: {len(news_urls)} 条新闻")
        print(f"其中比赛相关: {len(competition_news)} 条")
        print(f"其他新闻: {len(other_news)} 条")
    else:
        print("\n未找到任何新闻")

if __name__ == "__main__":
    main() 