import os
import re
import shutil
from datetime import datetime
import logging

def parse_chinese_date(date_str):
    """
    解析中文日期格式，如 "2024年1月12日"
    
    :param date_str: 中文日期字符串
    :return: datetime 对象
    """
    # 处理包含地点的文件夹名称，如 "xx公寓, 2024年1月12日"
    date_str = date_str.split(', ')[-1]
    
    # 使用正则表达式提取年、月、日
    match = re.match(r'(\d{4})年(\d{1,2})月(\d{1,2})日', date_str)
    if match:
        year = int(match.group(1))
        month = int(match.group(2))
        day = int(match.group(3))
        return datetime(year, month, day)
    return None

def organize_folders(base_directory, mode='date', custom_pattern=None):
    """
    文件夹整理工具，支持多种整理模式
    
    :param base_directory: 要整理的基本目录
    :param mode: 整理模式 ('date', 'size', 'type', 'custom')
    :param custom_pattern: 自定义整理模式的函数或模式
    """
    # 配置日志
    logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s: %(message)s')
    logger = logging.getLogger(__name__)

    try:
        # 确保基本目录存在
        if not os.path.exists(base_directory):
            raise ValueError(f"目录 {base_directory} 不存在")

        # 按日期整理
        if mode == 'date':
            # 用于存储每个月份的文件夹列表
            month_folders = {}

            # 第一步：收集并分类文件夹
            for folder_name in os.listdir(base_directory):
                folder_path = os.path.join(base_directory, folder_name)

                if os.path.isdir(folder_path):
                    try:
                        # 尝试解析中文日期
                        date_obj = parse_chinese_date(folder_name)
                        
                        if date_obj:
                            month_key = date_obj.strftime('%m')
                            # 如果这个月份还没有对应的列表，就创建一个
                            if month_key not in month_folders:
                                month_folders[month_key] = []
                            
                            # 将文件夹信息添加到对应月份的列表中
                            month_folders[month_key].append({
                                'name': folder_name,
                                'path': folder_path,
                                'date': date_obj
                            })
                        else:
                            logger.warning(f"无法处理文件夹 {folder_name}")
                    except Exception as e:
                        logger.warning(f"处理文件夹 {folder_name} 时出错: {e}")

            # 第二步：合并同月份的文件夹
            for month, folders in month_folders.items():
                # 创建月份文件夹（不带"月"字）
                month_folder_path = os.path.join(base_directory, month)
                os.makedirs(month_folder_path, exist_ok=True)

                # 按日期排序文件夹
                sorted_folders = sorted(folders, key=lambda x: x['date'])

                for folder_info in sorted_folders:
                    try:
                        # 提取日期部分，确保两位数
                        day = folder_info['date'].strftime('%d')
                        
                        # 移动文件夹到月份文件夹，并重命名为日期
                        dest_path = os.path.join(month_folder_path, day)
                        shutil.move(folder_info['path'], dest_path)
                        logger.info(f"移动文件夹 {folder_info['name']} 到 {month}/{day}")
                    except Exception as e:
                        logger.warning(f"移动文件夹 {folder_info['name']} 失败: {e}")

        # 按文件大小整理
        elif mode == 'size':
            size_categories = {
                'small': 0,
                'medium': 100 * 1024 * 1024,  # 100MB
                'large': 1 * 1024 * 1024 * 1024  # 1GB
            }
            
            for category, size_limit in size_categories.items():
                category_path = os.path.join(base_directory, category)
                os.makedirs(category_path, exist_ok=True)

            for item in os.listdir(base_directory):
                item_path = os.path.join(base_directory, item)
                if os.path.isdir(item_path):
                    total_size = sum(os.path.getsize(os.path.join(dirpath, filename)) 
                                     for dirpath, _, filenames in os.walk(item_path) 
                                     for filename in filenames)
                    
                    if total_size < size_categories['medium']:
                        dest = os.path.join(base_directory, 'small')
                    elif total_size < size_categories['large']:
                        dest = os.path.join(base_directory, 'medium')
                    else:
                        dest = os.path.join(base_directory, 'large')
                    
                    shutil.move(item_path, os.path.join(dest, item))
                    logger.info(f"移动文件夹 {item} 到 {dest}")

        # 按文件类型整理
        elif mode == 'type':
            for item in os.listdir(base_directory):
                item_path = os.path.join(base_directory, item)
                if os.path.isdir(item_path):
                    for root, _, files in os.walk(item_path):
                        for file in files:
                            file_ext = os.path.splitext(file)[1][1:].lower()
                            type_path = os.path.join(base_directory, file_ext)
                            os.makedirs(type_path, exist_ok=True)
                            
                            source_file = os.path.join(root, file)
                            dest_file = os.path.join(type_path, file)
                            shutil.copy2(source_file, dest_file)
                    
                    logger.info(f"处理文件夹 {item} 的文件类型")

        # 自定义整理模式
        elif mode == 'custom' and custom_pattern:
            if callable(custom_pattern):
                custom_pattern(base_directory)
            else:
                logger.warning("自定义模式必须是可调用的函数")

        else:
            logger.error(f"不支持的整理模式: {mode}")

    except Exception as e:
        logger.error(f"文件夹整理出错: {e}")

def custom_organize_example(base_directory):
    """自定义整理的示例函数"""
    print(f"使用自定义方法整理 {base_directory}")
    # 在这里添加您的自定义整理逻辑

if __name__ == "__main__":
    print("文件夹整理工具")
    print("模式选择:")
    print("1. 按日期整理")
    print("2. 按大小整理")
    print("3. 按文件类型整理")
    print("4. 自定义整理")
    
    choice = input("请选择整理模式(1-4): ")
    base_dir = input("请输入要整理的文件夹路径: ")

    mode_map = {
        '1': 'date',
        '2': 'size',
        '3': 'type',
        '4': 'custom'
    }

    selected_mode = mode_map.get(choice, 'date')
    
    if selected_mode == 'custom':
        organize_folders(base_dir, mode='custom', custom_pattern=custom_organize_example)
    else:
        organize_folders(base_dir, mode=selected_mode)
