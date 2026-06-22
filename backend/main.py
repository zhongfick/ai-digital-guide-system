from fastapi import FastAPI, HTTPException, UploadFile, File, Form
from fastapi.responses import HTMLResponse
from fastapi.staticfiles import StaticFiles
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
from datetime import datetime
import time
from pathlib import Path
import shutil
import uuid


# ===== 知识库管理 =====
BASE_DIR = Path(__file__).resolve().parent
KNOWLEDGE_DIR = BASE_DIR / "knowledge_docs"
KNOWLEDGE_DIR.mkdir(parents=True, exist_ok=True)
ALLOWED_KNOWLEDGE_EXTENSIONS = {".pdf", ".doc", ".docx", ".txt", ".md", ".xls", ".xlsx"}

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

# 缓存功能默认关闭，避免未定义变量导致 /chat 直接 500
cache_enabled = False

def get_cache_manager():
    return None


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


def _is_allowed_knowledge_file(filename: str) -> bool:
    return Path(filename).suffix.lower() in ALLOWED_KNOWLEDGE_EXTENSIONS


@app.get("/knowledge/files")
async def list_knowledge_files():
    files = []
    for file_path in sorted(KNOWLEDGE_DIR.iterdir(), key=lambda p: p.stat().st_mtime, reverse=True):
        if file_path.is_file():
            files.append({
                "name": file_path.name,
                "size": file_path.stat().st_size,
                "modified_at": datetime.fromtimestamp(file_path.stat().st_mtime).isoformat(),
            })
    return {"success": True, "data": files}


@app.post("/knowledge/upload")
async def upload_knowledge_file(file: UploadFile = File(...)):
    if not file.filename:
        raise HTTPException(status_code=400, detail="文件名不能为空")
    if not _is_allowed_knowledge_file(file.filename):
        raise HTTPException(status_code=400, detail="暂不支持该文件类型")

    safe_name = Path(file.filename).name
    target_path = KNOWLEDGE_DIR / f"{uuid.uuid4().hex}_{safe_name}"

    try:
        with target_path.open("wb") as buffer:
            shutil.copyfileobj(file.file, buffer)
    finally:
        await file.close()

    return {
        "success": True,
        "data": {
            "name": target_path.name,
            "original_name": safe_name,
        },
    }


@app.delete("/knowledge/files/{filename}")
async def delete_knowledge_file(filename: str):
    target_path = KNOWLEDGE_DIR / Path(filename).name
    if not target_path.exists() or not target_path.is_file():
        raise HTTPException(status_code=404, detail="文件不存在")
    target_path.unlink()
    return {"success": True}


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

        
        # 生成回答
        answer = await guide_system.generate_response(request.question)
        
        response_time = time.time() - start_time
        

        
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


if __name__ == "__main__":
    import uvicorn
    
    print("🚀 AI数字人导游API服务")

    uvicorn.run(app, host="0.0.0.0", port=8000, log_level="info")