import schedule
import time
from datetime import datetime
import sqlite3
import logging
from telegram.ext import Application, CommandHandler, ContextTypes
from telegram import Update
import asyncio
from test_spider import AdCompetitionSpider

# 配置日志
logging.basicConfig(
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
    level=logging.INFO
)

class TelegramBot:
    def __init__(self, token: str):
        """
        初始化Telegram机器人
        :param token: Telegram Bot Token
        """
        self.token = token
        self.application = Application.builder().token(token).build()
        self.chat_ids = set()  # 存储订阅用户的chat_id
        self.setup_handlers()

    def setup_handlers(self):
        """设置命令处理器"""
        self.application.add_handler(CommandHandler("start", self.start_command))
        self.application.add_handler(CommandHandler("subscribe", self.subscribe_command))
        self.application.add_handler(CommandHandler("unsubscribe", self.unsubscribe_command))

    async def start_command(self, update: Update, context: ContextTypes.DEFAULT_TYPE):
        """处理/start命令"""
        welcome_text = """
欢迎使用比赛信息推送机器人！
可用命令：
/subscribe - 订阅比赛信息
/unsubscribe - 取消订阅
        """
        await update.message.reply_text(welcome_text)

    async def subscribe_command(self, update: Update, context: ContextTypes.DEFAULT_TYPE):
        """处理/subscribe命令"""
        chat_id = update.effective_chat.id
        self.chat_ids.add(chat_id)
        await update.message.reply_text("订阅成功！您将收到最新的比赛信息推送。")

    async def unsubscribe_command(self, update: Update, context: ContextTypes.DEFAULT_TYPE):
        """处理/unsubscribe命令"""
        chat_id = update.effective_chat.id
        self.chat_ids.discard(chat_id)
        await update.message.reply_text("已取消订阅。")

    async def send_message(self, message: str):
        """向所有订阅用户发送消息"""
        for chat_id in self.chat_ids:
            try:
                await self.application.bot.send_message(
                    chat_id=chat_id,
                    text=message,
                    parse_mode='HTML'
                )
            except Exception as e:
                logging.error(f"发送消息失败: {str(e)}")

    def run(self):
        """运行机器人"""
        self.application.run_polling()

class CompetitionBot:
    def __init__(self, tg_token: str):
        self.db_path = 'competitions.db'
        self.init_database()
        self.ad_spider = AdCompetitionSpider()
        self.tg_bot = TelegramBot(tg_token)
        
    def init_database(self):
        """初始化数据库"""
        conn = sqlite3.connect(self.db_path)
        c = conn.cursor()
        c.execute('''
            CREATE TABLE IF NOT EXISTS competitions
            (id TEXT PRIMARY KEY,
             title TEXT,
             url TEXT,
             date_info TEXT,
             requirements TEXT,
             organizer TEXT,
             undertaker TEXT,
             platform TEXT,
             created_at TIMESTAMP)
        ''')
        conn.commit()
        conn.close()

    def save_competition(self, competition):
        """保存比赛信息到数据库"""
        conn = sqlite3.connect(self.db_path)
        c = conn.cursor()
        try:
            c.execute('''
                INSERT INTO competitions 
                (id, title, url, date_info, requirements, organizer, undertaker, platform, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ''', (
                str(competition['index']),  # 使用新闻索引作为ID
                competition['title'],
                competition['url'],
                competition.get('date_info', ''),
                competition.get('requirements', ''),
                competition.get('organizer', ''),
                competition.get('undertaker', ''),
                '大广赛',
                datetime.now()
            ))
            conn.commit()
            return True
        except sqlite3.IntegrityError:
            return False
        finally:
            conn.close()

    async def push_message(self, competition):
        """推送比赛信息到Telegram"""
        message = f"""
<b>发现新比赛！</b>
<b>标题：</b>{competition['title']}
<b>平台：</b>大广赛
<b>报名日期：</b>{competition.get('date_info', '未找到')}
<b>参赛要求：</b>{competition.get('requirements', '未找到')}
<b>主办方：</b>{competition.get('organizer', '未找到')}
<b>承办方：</b>{competition.get('undertaker', '未找到')}
<b>详情链接：</b>{competition['url']}
        """
        await self.tg_bot.send_message(message)

    async def run_task(self):
        """执行定时任务"""
        news_urls = self.ad_spider.fetch_news_urls()
        competition_news = [news for news in news_urls if news['is_competition']]
        
        for competition in competition_news:
            if 'content' in competition and self.save_competition(competition):  # 如果是新比赛且有详细内容
                await self.push_message(competition)

async def main():
    # 替换为您的Telegram Bot Token
    BOT_TOKEN = "YOUR_TELEGRAM_BOT_TOKEN"
    
    bot = CompetitionBot(BOT_TOKEN)
    
    # 创建定时任务
    async def scheduled_task():
        while True:
            await bot.run_task()
            await asyncio.sleep(12 * 3600)  # 12小时
    
    # 运行Telegram机器人和定时任务
    await asyncio.gather(
        bot.tg_bot.application.run_polling(),
        scheduled_task()
    )

if __name__ == "__main__":
    asyncio.run(main())
