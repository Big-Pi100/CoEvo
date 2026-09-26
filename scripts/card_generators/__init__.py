# 卡片生成器路由表
from .science import science_generator
from .history import history_generator
from .geography import geography_generator
from .politics import politics_generator
from .chinese_lang import chinese_generator
from .english_lang import english_generator
from .japanese_lang import japanese_generator
from .russian_lang import russian_generator
from .it import it_generator

ROUTER = {
    "physics": science_generator,
    "chemistry": science_generator,
    "math": science_generator,
    "biology": science_generator,
    "science": science_generator,
    "history": history_generator,
    "geography": geography_generator,
    "politics": politics_generator,
    "chinese": chinese_generator,
    "english": english_generator,
    "japanese": japanese_generator,
    "russian": russian_generator,
    "it": it_generator,
    "pe": science_generator,
}
