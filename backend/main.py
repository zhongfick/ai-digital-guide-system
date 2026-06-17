from fastapi import FastAPI, HTTPException
from fastapi.staticfiles import StaticFiles
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
from datetime import datetime
import os
import json
import time
from fastapi import UploadFile, File, Form, Query
import shutil
from pathlib import Path
import json
from datetime import datetime
from collections import Counter
import re
from datetime import timedelta

# ===== 知识库管理 =====
KNOWLEDGE_DIR = Path("knowledge_docs")
KNOWLEDGE_DIR.mkdir(exist_ok=True)

# 情感词典（简单版）
POSITIVE_WORDS = ['好', '棒', '赞', '喜欢', '满意', '漂亮', '美', '开心', '感谢', '不错', '很好', '非常']
NEGATIVE_WORDS = ['差', '烂', '不好', '不满意', '贵', '失望', '无聊', '没意思', '太差', '很差']

# 尝试导入AI导游系统
try:
    from ai_guide_system import AIGuideSystem
    print("✅ 尝试导入AI导游系统...")
    guide_system = AIGuideSystem()  # 初始化你的系统
    print("✅ AI导游系统初始化成功")
except ImportError as e:
    print(f"⚠️  无法导入AI导游系统: {e}")
    print("⚠️  将使用模拟回复模式")
    guide_system = None
except Exception as e:
    print(f"❌ AI导游系统初始化失败: {e}")
    guide_system = None

# 尝试导入缓存管理器
try:
    from cache_manager import init_cache, get_cache_manager, shutdown_cache
    print("✅ 缓存管理器已导入")
    cache_enabled = True
except ImportError as e:
    print(f"⚠️  缓存管理器导入失败: {e}")
    cache_enabled = False

app = FastAPI(
    title="AI数字人导游系统 API",
    description="景区智能导览系统后端接口",
    version="1.0.0"
)


app.mount("/static", StaticFiles(directory="D:/AI_Guide_Project/backend/static"), name="static")

# 允许跨域（重要：如果前端是网页）
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],  # 生产环境应该限制具体域名
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

@app.post("/admin/knowledge/upload")
async def upload_knowledge(file: UploadFile = File(...), category: str = Form("general")):
    """上传景区知识文档（txt/docx/pdf），触发重建索引"""
    save_path = KNOWLEDGE_DIR / file.filename
    with open(save_path, "wb") as f:
        shutil.copyfileobj(file.file, f)
    # 可选：这里调用你的 build_knowledge_base 逻辑
    return {"status": "ok", "filename": file.filename, "category": category}

@app.get("/admin/knowledge/list")
async def list_knowledge():
    files = [{"name": f.name, "size": f.stat().st_size}
             for f in KNOWLEDGE_DIR.iterdir() if f.is_file()]
    return {"files": files}

# ===== 数字人形象配置 =====
CONFIG_PATH = Path("digital_person_config.json")

@app.post("/admin/persona/save")
async def save_persona(config: dict):
    CONFIG_PATH.write_text(json.dumps(config, ensure_ascii=False, indent=2))
    return {"status": "saved"}

@app.get("/admin/persona/get")
async def get_persona():
    if CONFIG_PATH.exists():
        return json.loads(CONFIG_PATH.read_text())
    return {"voice": "female_cn", "skin": "fair", "outfit": "traditional_blue"}

# ===== 反馈记录（游客端已调用 /feedback，这里加查询）=====
@app.get("/admin/feedback/list")
async def list_feedback(date: str = Query(None)):
    feedback_file = Path(f"logs/feedback_{date or datetime.now().strftime('%Y%m%d')}.log")
    if not feedback_file.exists():
        return {"feedbacks": []}
    lines = feedback_file.read_text(encoding="utf-8").splitlines()
    return {"feedbacks": [json.loads(l) for l in lines if l.strip()]}

@app.get("/admin/report/sentiment")
async def sentiment_report(days: int = 7):
    """生成游客感受度报告"""
    from pathlib import Path
    
    logs_dir = Path(r"D:\AI_Guide_Project\logs")
    today = datetime.now()
    
    # 读取最近 N 天的日志
    all_records = []
    for i in range(days):
        date_str = (today - timedelta(days=i)).strftime("%Y%m%d")
        log_file = logs_dir / f"chat_{date_str}.log"
        
        if log_file.exists():
            with open(log_file, "r", encoding="utf-8") as f:
                for line in f:
                    line = line.strip()
                    if line:
                        try:
                            data = json.loads(line)
                            all_records.append(data)
                        except:
                            pass
    
    if not all_records:
        return {
            "status": "ok",
            "total_records": 0,
            "message": "暂无对话记录"
        }
    
    # 1. 游客关注点分析
    questions = [r.get("question", "") for r in all_records if r.get("question")]
    
    # 提取关键词
    keywords = []
    for q in questions:
        # 简单分词（按常见标点分割）
        parts = re.split(r'[，。！？、；：""''（）\s]', q)
        for part in parts:
            if len(part) >= 2:  # 只保留2字以上的词
                keywords.append(part)
    
    keyword_counter = Counter(keywords)
    top_keywords = keyword_counter.most_common(10)
    
    # 按主题分类
    topics = {
        "景点介绍": 0,
        "门票价格": 0,
        "开放时间": 0,
        "交通路线": 0,
        "历史文化": 0,
        "美食推荐": 0,
        "游览建议": 0
    }
    
    topic_keywords = {
        "景点介绍": ["景点", "介绍", "特色", "风景", "好玩"],
        "门票价格": ["门票", "价格", "多少钱", "票价", "收费"],
        "开放时间": ["开放", "时间", "营业", "几点"],
        "交通路线": ["怎么去", "交通", "路线", "公交", "地铁", "开车"],
        "历史文化": ["历史", "文化", "故事", "传说", "由来"],
        "美食推荐": ["吃", "美食", "餐厅", "饭店", "好吃"],
        "游览建议": ["推荐", "建议", "路线", "游玩", "攻略"]
    }
    
    for q in questions:
        for topic, words in topic_keywords.items():
            for word in words:
                if word in q:
                    topics[topic] += 1
                    break
    
    # 2. 情感分析
    sentiments = []
    for record in all_records:
        question = record.get("question", "")
        answer = record.get("answer", "")
        
        # 分析问题情感
        pos_score = sum(1 for w in POSITIVE_WORDS if w in question)
        neg_score = sum(1 for w in NEGATIVE_WORDS if w in question)
        
        if pos_score > neg_score:
            sentiment = "positive"
        elif neg_score > pos_score:
            sentiment = "negative"
        else:
            sentiment = "neutral"
        
        sentiments.append({
            "timestamp": record.get("timestamp", ""),
            "question": question[:50],
            "sentiment": sentiment,
            "pos_score": pos_score,
            "neg_score": neg_score
        })
    
    # 统计情感分布
    sentiment_counts = Counter(s["sentiment"] for s in sentiments)
    total = len(sentiments)
    
    # 3. 生成服务建议
    suggestions = []
    
    # 基于关注点的建议
    if topics.get("门票价格", 0) > 3:
        suggestions.append("💰 游客对门票价格关注度高，建议在首页突出显示优惠政策")
    if topics.get("交通路线", 0) > 3:
        suggestions.append("🚗 游客频繁询问交通方式，建议增加详细交通指南")
    if topics.get("历史文化", 0) > 2:
        suggestions.append("📚 游客对历史文化感兴趣，建议增加深度讲解内容")
    
    # 基于情感的建议
    neg_count = sentiment_counts.get("negative", 0)
    if neg_count > total * 0.3:
        suggestions.append("😟 负面评价较多，建议检查服务质量并及时改进")
    elif neg_count > 0:
        suggestions.append("👍 整体满意度良好，继续保持服务质量")
    else:
        suggestions.append("🌟 游客满意度很高，建议保持当前服务水平")
    
    # 基于对话量的建议
    if len(all_records) < 10:
        suggestions.append("📢 对话量较少，建议加强推广引导游客使用")
    
    if not suggestions:
        suggestions.append("✅ 各项指标正常，无需特别调整")
    
    return {
        "status": "ok",
        "report_date": today.strftime("%Y-%m-%d"),
        "total_records": len(all_records),
        "analysis_days": days,
        
        # 1. 游客关注点分析
        "attention_analysis": {
            "top_keywords": [{"word": w, "count": c} for w, c in top_keywords],
            "topic_distribution": [{"topic": k, "count": v} for k, v in sorted(topics.items(), key=lambda x: -x[1])],
            "total_questions": len(questions)
        },
        
        # 2. 情感趋势
        "sentiment_analysis": {
            "overall": {
                "positive": sentiment_counts.get("positive", 0),
                "neutral": sentiment_counts.get("neutral", 0),
                "negative": sentiment_counts.get("negative", 0),
                "positive_rate": round(sentiment_counts.get("positive", 0) / total * 100, 1) if total > 0 else 0
            },
            "trend": sentiments[-20:] if len(sentiments) > 20 else sentiments  # 最近20条的情感趋势
        },
        
        # 3. 服务建议
        "suggestions": suggestions,
        
        # 4. 每日统计
        "daily_stats": []
    }

# ===== 统计接口（给大屏用）=====
@app.get("/admin/stats/dashboard")
async def dashboard_stats():
    """管理后台数据大屏接口"""
    import os
    from pathlib import Path
    
    # 直接指定绝对路径
    logs_dir = Path(r"D:\AI_Guide_Project\logs")
    knowledge_dir = Path(r"D:\AI_Guide_Project\knowledge_docs")
    
    today = datetime.now().strftime("%Y%m%d")
    chat_log = logs_dir / f"chat_{today}.log"
    
    chat_count = 0
    hot_questions = {}
    
    # 检查日志文件是否存在
    print(f"📂 检查日志文件: {chat_log}")
    print(f"   文件存在: {chat_log.exists()}")
    
    if chat_log.exists():
        print(f"   文件大小: {chat_log.stat().st_size} bytes")
        
        with open(chat_log, "r", encoding="utf-8") as f:
            for line_num, line in enumerate(f, 1):
                line = line.strip()
                if not line:
                    continue
                    
                chat_count += 1
                print(f"   第{line_num}行: {line[:80]}...")
                
                try:
                    data = json.loads(line)
                    # 尝试多种可能的字段名
                    question = data.get("question") or data.get("query") or ""
                    if question:
                        q_short = question[:20]
                        hot_questions[q_short] = hot_questions.get(q_short, 0) + 1
                        print(f"     -> 问题: {q_short}")
                except json.JSONDecodeError as e:
                    print(f"     ⚠️ JSON解析失败: {e}")
    
    # 统计知识库文档数
    knowledge_count = 0
    if knowledge_dir.exists():
        knowledge_count = len(list(knowledge_dir.glob("*")))
    
    # 排序热门问题
    top_hot = sorted(hot_questions.items(), key=lambda x: -x[1])[:5]
    
    result = {
        "today_chats": chat_count,
        "hot_questions": [{"q": q, "count": c} for q, c in top_hot],
        "knowledge_count": knowledge_count,
        "status": "ok",
        "debug_info": {
            "log_file": str(chat_log),
            "log_exists": chat_log.exists(),
            "log_size": chat_log.stat().st_size if chat_log.exists() else 0,
            "lines_read": chat_count
        }
    }
    
    print(f"✅ 返回结果: {json.dumps(result, ensure_ascii=False, indent=2)}")
    return result

# 应用启动事件 - 初始化缓存
@app.on_event("startup")
async def startup_event():
    """应用启动时初始化缓存"""
    global cache_enabled
    if cache_enabled:
        try:
            redis_url = os.getenv("REDIS_URL", "redis://localhost:6379")
            await init_cache(redis_url, default_ttl=3600)
            cache_mgr = get_cache_manager()
            if cache_mgr and cache_mgr.connected:
                stats = await cache_mgr.get_stats()
                print(f"✅ 缓存系统已启动: {stats}")
            else:
                print("⚠️  缓存系统启动失败，将使用无缓存模式")
                cache_enabled = False
        except Exception as e:
            print(f"❌ 缓存初始化异常: {e}，将使用无缓存模式")
            cache_enabled = False

# 应用关闭事件 - 关闭缓存
@app.on_event("shutdown")
async def shutdown_event():
    """应用关闭时断开缓存连接"""
    if cache_enabled:
        await shutdown_cache()
        print("✓ 缓存连接已关闭")

# 数据模型
class ChatRequest(BaseModel):
    user_id: str
    question: str
    session_id: str = "default"

class FeedbackRequest(BaseModel):
    user_id: str
    session_id: str
    question: str
    answer: str
    rating: int  # 1-5分
    feedback: str = ""

# 创建日志目录
os.makedirs("logs", exist_ok=True)

# 首页路由
@app.get("/")
async def root():
    return {
        "message": "🏔️ AI数字人导游API服务",
        "status": "running",
        "endpoints": {
            "health_check": "/health",
            "chat": "/chat (POST)",
            "api_docs": "/docs 或 /redoc",
            "stats": "/stats"
        },
        "timestamp": datetime.now().isoformat()
    }

# 健康检查路由
@app.get("/health")
async def health_check():
    """健康检查接口，用于测试服务是否正常"""
    return {
        "status": "healthy" if guide_system else "degraded",
        "service": "ai-guide-api",
        "version": "1.0.0",
        "knowledge_base": "loaded" if guide_system and guide_system.knowledge_base else "not_loaded",
        "llm": "available" if guide_system and guide_system.llm else "unavailable",
        "timestamp": datetime.now().isoformat()
    }

# AI对话接口
@app.post("/chat")
async def chat_with_ai(request: ChatRequest):
    """AI导游对话接口"""
    try:
        start_time = time.time()
        
        if not guide_system:
            raise HTTPException(
                status_code=503, 
                detail="AI系统未初始化，请检查后端日志"
            )
        
        # 尝试从缓存获取
        cache_key = f"chat:{request.user_id}:{hash(request.question) % 1000000}"
        cache_mgr = get_cache_manager() if cache_enabled else None
        
        cached_answer = None
        if cache_mgr and cache_mgr.connected:
            cached_answer = await cache_mgr.get(cache_key)
            if cached_answer:
                response_time = time.time() - start_time
                return {
                    "success": True,
                    "data": {
                        "answer": cached_answer,
                        "response_time": round(response_time, 3),
                        "from_cache": True
                    },
                    "user_id": request.user_id,
                    "session_id": request.session_id,
                    "timestamp": datetime.now().isoformat()
                }
        
        # 生成回答
        answer = await guide_system.generate_response(request.question)
        
        response_time = time.time() - start_time
        
        # 存入缓存
        if cache_mgr and cache_mgr.connected:
            await cache_mgr.set(cache_key, answer, ttl=3600)
        
        # 保存对话日志
        save_chat_log(
            request.user_id, 
            request.session_id, 
            request.question, 
            answer, 
            response_time
        )
        
        return {
            "success": True,
            "data": {
                "answer": answer,
                "response_time": round(response_time, 3),
                "from_cache": False
            },
            "user_id": request.user_id,
            "session_id": request.session_id,
            "timestamp": datetime.now().isoformat()
        }
        
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

# 反馈接口
@app.post("/feedback")
async def submit_feedback(feedback: FeedbackRequest):
    """接收用户反馈，用于改进系统"""
    try:
        feedback_data = {
            "timestamp": datetime.now().isoformat(),
            "user_id": feedback.user_id,
            "session_id": feedback.session_id,
            "question": feedback.question,
            "answer": feedback.answer,
            "rating": feedback.rating,
            "feedback": feedback.feedback
        }
        
        # 保存反馈
        feedback_file = f"logs/feedback_{datetime.now().strftime('%Y%m%d')}.log"
        with open(feedback_file, "a", encoding="utf-8") as f:
            f.write(json.dumps(feedback_data, ensure_ascii=False) + "\n")
        
        return {"success": True, "message": " 反馈已收到，谢谢！"}
        
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

# 统计接口
@app.get("/stats")
async def get_stats():
    """获取系统统计数据"""
    try:
        # 统计今日对话数量
        today = datetime.now().strftime('%Y%m%d')
        log_file = f"logs/chat_{today}.log"
        
        chat_count = 0
        if os.path.exists(log_file):
            with open(log_file, "r", encoding="utf-8") as f:
                chat_count = len(f.readlines())
        
        # 获取缓存统计
        cache_stats = {}
        if cache_enabled:
            cache_mgr = get_cache_manager()
            if cache_mgr:
                cache_stats = await cache_mgr.get_stats()
        
        return {
            "success": True,
            "data": {
                "today_chats": chat_count,
                "service_uptime": datetime.now().isoformat(),
                "knowledge_base_status": "loaded" if guide_system and guide_system.knowledge_base else "not_loaded",
                "cache": cache_stats if cache_stats else {"status": "disabled"}
            }
        }
        
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

# 缓存管理接口
@app.get("/cache/status")
async def cache_status():
    """获取缓存状态"""
    if not cache_enabled:
        return {
            "success": True,
            "cache_enabled": False,
            "message": "缓存功能未启用"
        }
    
    try:
        cache_mgr = get_cache_manager()
        if not cache_mgr:
            return {
                "success": False,
                "cache_enabled": False,
                "error": "缓存管理器未初始化"
            }
        
        stats = await cache_mgr.get_stats()
        return {
            "success": True,
            "cache_enabled": cache_mgr.connected,
            "stats": stats
        }
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

@app.post("/cache/clear")
async def cache_clear(pattern: str = "*"):
    """清空缓存"""
    if not cache_enabled:
        raise HTTPException(status_code=400, detail="缓存功能未启用")
    
    try:
        cache_mgr = get_cache_manager()
        if not cache_mgr or not cache_mgr.connected:
            raise HTTPException(status_code=503, detail="缓存服务不可用")
        
        deleted = await cache_mgr.clear_pattern(pattern)
        return {
            "success": True,
            "message": f"已清除 {deleted} 个缓存记录",
            "pattern": pattern
        }
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

def save_chat_log(user_id, session_id, question, answer, response_time):
    """保存对话日志（修复编码问题）"""
    import json
    from pathlib import Path
    
    log_entry = {
        "timestamp": datetime.now().isoformat(),
        "user_id": user_id,
        "session_id": session_id,
        "question": question,
        "answer": answer,
        "response_time": f"{response_time:.3f}s"
    }
    
    # 确保 logs 目录存在
    logs_dir = Path("logs")
    logs_dir.mkdir(exist_ok=True)
    
    # 保存到文件（指定 utf-8 编码）
    log_file = logs_dir / f"chat_{datetime.now().strftime('%Y%m%d')}.log"
    with open(log_file, "a", encoding="utf-8") as f:
        json_str = json.dumps(log_entry, ensure_ascii=False)
        f.write(json_str + "\n")
    
    print(f"📝 已保存对话日志: {log_file}")

if __name__ == "__main__":
    import uvicorn
    
    print("=" * 60)
    print("🚀 AI数字人导游API服务")
    print("=" * 60)
    print("📡 启动信息:")
    print(f"   服务地址: http://0.0.0.0:8000")
    print(f"   本地访问: http://127.0.0.1:8000")
    print(f"   网络访问: http://192.168.0.105:8000 (你的WiFi IP)")
    print("📚 API文档:")
    print(f"   交互文档: http://localhost:8000/docs")
    print(f"   备用文档: http://localhost:8000/redoc")
    print("🔧 测试接口:")
    print(f"   健康检查: http://localhost:8000/health")
    print(f"   首页: http://localhost:8000/")
    print(f"   缓存状态: http://localhost:8000/cache/status")
    print("=" * 60)
    
    uvicorn.run(app, host="0.0.0.0", port=8000, log_level="info")