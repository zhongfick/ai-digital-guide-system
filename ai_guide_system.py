# ai_guide_system.py
# AI导游完整系统 - 修复版

import os
import sys
from typing import List, Dict, Any
import json
import time
from datetime import datetime
from pathlib import Path
import traceback  # 添加这个用于调试


class LocalSentenceTransformerEmbeddings:
    """本地 SentenceTransformer 嵌入包装器。"""
    def __init__(self, model_name: str):
        from sentence_transformers import SentenceTransformer

        self.model = SentenceTransformer(model_name, local_files_only=True)

    def embed_documents(self, texts: List[str]) -> List[List[float]]:
        embeddings = self.model.encode(texts, show_progress_bar=False, convert_to_numpy=True)
        return [vec.tolist() for vec in embeddings]

    def embed_query(self, text: str) -> List[float]:
        vec = self.model.encode([text], show_progress_bar=False, convert_to_numpy=True)
        return vec[0].tolist()


class HashingVectorizerEmbeddings:
    """HashingVectorizer 作为最后的离线回退。"""
    def __init__(self, dim: int = 768):
        from sklearn.feature_extraction.text import HashingVectorizer

        self.dim = dim
        self.vectorizer = HashingVectorizer(n_features=dim, alternate_sign=False)

    def _normalize(self, vector):
        import numpy as np

        arr = np.asarray(vector, dtype=float)
        norm = np.linalg.norm(arr)
        if norm == 0:
            return arr.tolist()
        return (arr / norm).tolist()

    def embed_documents(self, texts: List[str]) -> List[List[float]]:
        arr = self.vectorizer.transform(texts).toarray()
        import numpy as np

        norms = np.linalg.norm(arr, axis=1, keepdims=True)
        norms[norms == 0] = 1
        return (arr / norms).tolist()

    def embed_query(self, text: str) -> List[float]:
        vec = self.vectorizer.transform([text]).toarray()[0]
        return self._normalize(vec)


# DeepSeek API key should be provided via environment variable DEEPSEEK_API_KEY
DEEPSEEK_API_KEY = os.environ.get("DEEPSEEK_API_KEY", "")
if not DEEPSEEK_API_KEY:
    print("⚠️ 未设置 DEEPSEEK_API_KEY 环境变量，LLM 将不可用，系统将降级为无LLM模式.")

class AIGuideSystem:
    """AI导游系统"""
    
    def __init__(self, knowledge_base_path="my_scenic_faiss_index"):
        print("🚀 初始化AI导游系统...")
        
        # 1. 加载知识库
        self.knowledge_base = self.load_knowledge_base(knowledge_base_path)
        
        # 2. 初始化DeepSeek
        self.llm = self.init_deepseek_llm()
        
        # 3. 初始化对话历史
        self.conversation_history = []
        
        # 4. 初始化语音模块（可选）
        self.has_voice = False
        self.init_voice_module()
        
        print("✅ AI导游系统初始化完成！")
        print("-" * 50)
    
    def load_knowledge_base(self, kb_path: str):
        """加载向量知识库"""
        try:
            from langchain_community.vectorstores import FAISS

            print(f"📚 加载知识库: {kb_path}")

            embeddings = None
            try:
                from langchain_huggingface import HuggingFaceEmbeddings

                embeddings = HuggingFaceEmbeddings(
                    model_name="sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2"
                )
                print("✅ 使用 langchain_huggingface 的 HuggingFaceEmbeddings")
            except Exception as e:
                print("⚠️  未能使用 langchain_huggingface，尝试使用本地 SentenceTransformer。", e)
                try:
                    embeddings = LocalSentenceTransformerEmbeddings(
                        "sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2"
                    )
                    print("✅ 使用本地 SentenceTransformer 嵌入")
                except Exception as e2:
                    print("⚠️  本地 SentenceTransformer 加载失败，尝试回退到 HashingVectorizer。", e2)
                    embeddings = HashingVectorizerEmbeddings()
                    print("⚠️  注意：如果知识库是用 SentenceTransformer 构建，哈希向量回退可能导致搜索结果不准确。")

            # 加载FAISS索引
            path = Path(kb_path)
            if not path.exists():
                raise FileNotFoundError(f"知识库路径不存在: {kb_path}")

            pkl_path = path / "index.pkl"
            faiss_path = path / "index.faiss"
            metadata_path = path / "metadata.jsonl"

            if pkl_path.exists():
                db = FAISS.load_local(
                    str(path), embeddings, allow_dangerous_deserialization=True
                )
            elif faiss_path.exists() and metadata_path.exists():
                from langchain_community.vectorstores.faiss import dependable_faiss_import, DistanceStrategy
                from langchain_community.docstore.in_memory import InMemoryDocstore
                from langchain_core.documents import Document

                faiss_module = dependable_faiss_import()
                index = faiss_module.read_index(str(faiss_path))

                # 加载 metadata 并检查是否与 index 匹配
                docstore_data: Dict[int, Document] = {}
                with open(metadata_path, "r", encoding="utf-8") as meta_f:
                    for line_num, line in enumerate(meta_f, 1):
                        if not line.strip():
                            continue
                        try:
                            item = json.loads(line)
                            # 关键修复：确保 id 是整数
                            doc_id = int(item["id"]) if "id" in item else line_num
                            # 确保 text 是字符串
                            text_content = str(item.get("text", ""))
                            # 确保 metadata 是字典
                            metadata = dict(item.get("metadata", {})) if isinstance(item.get("metadata"), dict) else {}
                            
                            doc = Document(
                                page_content=text_content,
                                metadata=metadata
                            )
                            docstore_data[doc_id] = doc
                        except Exception as e:
                            print(f"⚠️  第 {line_num} 行元数据解析失败: {e}")
                            continue

                index_ids = faiss_module.vector_to_array(index.id_map)
                
                # 转换所有 id 为整数
                index_ids = [int(i) for i in index_ids]
                missing_ids = [i for i in index_ids if i not in docstore_data]
                
                if missing_ids:
                    raise ValueError(
                        f"FAISS 索引和 metadata.jsonl 不匹配。"
                        f"索引包含 {len(index_ids)} 向量，但 metadata 只包含 {len(docstore_data)} 条记录。"
                        f"缺失的示例 id: {missing_ids[:10]}..."
                    )

                index_to_docstore_id: Dict[int, int] = {i: i for i in index_ids}
                docstore = InMemoryDocstore(docstore_data)
                db = FAISS(
                    embeddings,
                    index,
                    docstore,
                    index_to_docstore_id,
                    normalize_L2=False,
                    distance_strategy=DistanceStrategy.MAX_INNER_PRODUCT,
                )
            else:
                raise FileNotFoundError(
                    "未找到 index.pkl 或 index.faiss + metadata.jsonl。请检查 my_scenic_faiss_index 目录。"
                )

            # 测试知识库
            test_query = "灵山大佛"
            results = db.similarity_search(test_query, k=1)
            print(f"  知识库测试查询成功，找到 {len(results)} 个相关文档")

            return db

        except Exception as e:
            print(f"❌ 加载知识库失败: {e}")
            traceback.print_exc()  # 打印详细错误
            print("⚠️  将使用无知识库模式")
            return None
    
    def init_deepseek_llm(self):
        """初始化DeepSeek LLM"""
        if not DEEPSEEK_API_KEY:
            print("⚠️ DEEPSEEK_API_KEY 未配置，跳过 LLM 初始化")
            return None
        try:
            from langchain_openai import ChatOpenAI
            
            # 注意：我们使用OpenAI兼容的接口
            llm = ChatOpenAI(
                api_key=DEEPSEEK_API_KEY,
                base_url="https://api.deepseek.com",
                model="deepseek-chat",
                temperature=0.3,  # 较低的温度，使回答更一致
                max_tokens=1024,
                timeout=30
            )
            
            print("🧠 DeepSeek LLM 初始化成功")
            return llm
            
        except Exception as e:
            print(f"❌ 初始化DeepSeek失败: {e}")
            return None
    
    def init_voice_module(self):
        """初始化语音模块"""
        try:
            # 尝试导入语音相关库
            import pyttsx3
            import speech_recognition as sr
            
            self.tts_engine = pyttsx3.init()
            self.tts_engine.setProperty('rate', 150)  # 语速
            self.tts_engine.setProperty('volume', 0.9)  # 音量
            
            self.recognizer = sr.Recognizer()
            
            self.has_voice = True
            print("🎤 语音模块初始化成功")
            
        except ImportError:
            print("⚠️  未安装语音库，将使用纯文本模式")
            print("   安装命令: pip install pyttsx3 speechrecognition")
            self.has_voice = False
        except Exception as e:
            print(f"⚠️  语音模块初始化失败: {e}")
            self.has_voice = False
    
    def search_knowledge(self, query: str, k: int = 3) -> List[str]:
        """从知识库搜索相关信息"""
        if not self.knowledge_base:
            return ["无知识库信息"]
        
        try:
            # 搜索相关文档
            docs = self.knowledge_base.similarity_search(query, k=k)
            
            # 提取内容
            contexts = []
            for i, doc in enumerate(docs):
                content = doc.page_content.strip()
                if len(content) > 500:  # 截断过长的内容
                    content = content[:500] + "..."
                contexts.append(f"[相关信息{i+1}]: {content}")
            
            return contexts
            
        except Exception as e:
            print(f"⚠️ 知识搜索失败: {e}")
            return ["知识库搜索出错"]
    
    def build_prompt(self, query: str, contexts: List[str]) -> str:
        """构建提示词"""
        context_text = "\n\n".join(contexts)
        
        prompt = f"""你是一个专业的AI导游，专门为游客提供景区信息和服务。

用户的问题：{query}

相关的景区信息：
{context_text}

请根据以上信息，以专业导游的身份回答用户的问题：

要求：
1. 回答要准确、专业、热情
2. 如果信息充分，给出详细的解答
3. 如果信息不充分，可以结合常识，但要说明
4. 回答结构清晰，语言亲切自然
5. 如果有具体数据（如开放时间、票价、高度等），请明确给出
6. 可以适当加入游览建议，但不要编造不存在的信息

请用中文回答，开头可以用"亲爱的游客朋友"等亲切称呼。
"""
        return prompt
    
    async def generate_response(self, query: str) -> str:
        """异步生成回答：优先使用 LLM 的异步方法，否则在线程池中运行阻塞调用。"""
        if not self.llm:
            return "抱歉，AI服务暂时不可用。"
        
        try:
            # 1. 搜索知识库
            print(f"🔍 搜索知识库: {query}")
            contexts = self.search_knowledge(query)
            
            # 2. 构建提示词
            prompt = self.build_prompt(query, contexts)
            
            # 3. 调用 LLM（优先使用异步接口）
            print("🤔 正在思考（异步调用）...")
            start_time = time.time()
            import asyncio
            answer = None

            # 如果 LLM 提供异步接口，优先使用
            if hasattr(self.llm, "ainvoke"):
                try:
                    response = await self.llm.ainvoke(prompt)
                    answer = getattr(response, 'content', str(response))
                except Exception:
                    pass
            elif hasattr(self.llm, "agenerate"):
                try:
                    response = await self.llm.agenerate(prompt)
                    answer = getattr(response, 'content', str(response))
                except Exception:
                    pass

            # 回退到在线程池中执行阻塞调用（仍然对外表现为异步）
            if answer is None:
                response = await asyncio.to_thread(self.llm.invoke, prompt)
                answer = getattr(response, 'content', str(response)) if hasattr(response, 'content') else str(response)

            time_used = time.time() - start_time

            # 4. 保存到对话历史
            self.conversation_history.append({
                "timestamp": datetime.now().isoformat(),
                "query": query,
                "answer": answer,
                "time_used": f"{time_used:.2f}s"
            })

            print(f"✅ 回答生成完成 (用时: {time_used:.2f}秒)")
            return answer

        except Exception as e:
            print(f"❌ 生成回答时出错: {e}")
            traceback.print_exc()
            return f"抱歉，生成回答时出错: {str(e)}"
    
    def text_to_speech(self, text: str):
        """文本转语音"""
        if not self.has_voice:
            return
        
        try:
            # 保存到文件
            import pyttsx3
            engine = pyttsx3.init()
            
            # 设置语音属性
            voices = engine.getProperty('voices')
            for voice in voices:
                if 'chinese' in voice.name.lower() or 'zh' in voice.id.lower():
                    engine.setProperty('voice', voice.id)
                    break
            
            engine.say(text)
            engine.runAndWait()
            
        except Exception as e:
            print(f"⚠️ 语音播报失败: {e}")
    
    def speech_to_text(self) -> str:
        """语音转文本"""
        if not self.has_voice:
            return ""
        
        try:
            import speech_recognition as sr
            
            with sr.Microphone() as source:
                print("🎤 请说话（3秒后开始录音）...")
                self.recognizer.adjust_for_ambient_noise(source, duration=1)
                print("🔴 录音中...")
                
                try:
                    audio = self.recognizer.listen(source, timeout=5, phrase_time_limit=10)
                    print("✅ 录音完成，识别中...")
                    
                    text = self.recognizer.recognize_google(audio, language='zh-CN')
                    print(f"📝 识别结果: {text}")
                    return text
                    
                except sr.UnknownValueError:
                    print("❌ 无法识别语音")
                    return ""
                except sr.RequestError as e:
                    print(f"❌ 语音识别服务错误: {e}")
                    return ""
                except Exception as e:
                    print(f"❌ 录音失败: {e}")
                    return ""
                    
        except Exception as e:
            print(f"❌ 语音输入失败: {e}")
            return ""
    
    def chat_loop(self):
        """主聊天循环"""
        print("\n" + "="*60)
        print("🏔️  AI导游系统已启动")
        print("="*60)
        print("📝 使用说明:")
        print("  1. 输入 'exit' 或 '退出' 结束对话")
        print("  2. 输入 'voice' 或 '语音' 切换到语音输入")
        print("  3. 输入 'text' 或 '文本' 切换回文本输入")
        print("  4. 输入 'history' 或 '历史' 查看对话历史")
        print("  5. 输入 'help' 或 '帮助' 查看帮助")
        print("="*60)
        
        use_voice_input = False
        
        while True:
            try:
                # 获取用户输入
                if use_voice_input:
                    print("\n🎤 语音模式 (等待说话...)")
                    query = self.speech_to_text()
                    if not query:
                        print("请重新尝试或输入 'text' 切换到文本模式")
                        continue
                else:
                    query = input("\n👤 请输入您的问题: ").strip()
                
                # 处理特殊命令
                if query.lower() in ['exit', '退出', 'quit']:
                    print("👋 感谢使用AI导游，再见！")
                    break
                
                elif query.lower() in ['voice', '语音', 'voice mode']:
                    if self.has_voice:
                        use_voice_input = True
                        print("✅ 已切换到语音输入模式")
                    else:
                        print("❌ 语音模块未启用")
                    continue
                
                elif query.lower() in ['text', '文本', 'text mode']:
                    use_voice_input = False
                    print("✅ 已切换到文本输入模式")
                    continue
                
                elif query.lower() in ['history', '历史', '对话历史']:
                    self.show_history()
                    continue
                
                elif query.lower() in ['help', '帮助']:
                    self.show_help()
                    continue
                
                elif query.lower() in ['clear', '清空', 'clear history']:
                    self.conversation_history = []
                    print("✅ 对话历史已清空")
                    continue
                
                # 空输入处理
                if not query:
                    continue
                
                # 生成回答
                print("\n🤖 AI导游正在思考...")
                answer = self.generate_response(query)
                
                # 显示回答
                print(f"\n{'='*40}")
                print("🤖 AI导游:")
                print(f"{answer}")
                print(f"{'='*40}")
                
                # 语音播报
                if self.has_voice and len(answer) < 500:  # 避免播报过长的回答
                    play_voice = input("\n🔊 是否语音播报？(y/n): ").lower()
                    if play_voice == 'y':
                        self.text_to_speech(answer)
                        print("✅ 语音播报完成")
                
            except KeyboardInterrupt:
                print("\n\n👋 用户中断，感谢使用！")
                break
            except Exception as e:
                print(f"❌ 系统错误: {e}")
                traceback.print_exc()
    
    def show_history(self):
        """显示对话历史"""
        if not self.conversation_history:
            print("📜 暂无对话历史")
            return
        
        print("\n📜 对话历史:")
        print("-" * 60)
        for i, item in enumerate(self.conversation_history[-10:], 1):  # 显示最近10条
            print(f"{i}. [{item['timestamp'][11:19]}]")
            print(f"   用户: {item['query'][:50]}{'...' if len(item['query']) > 50 else ''}")
            print(f"   回答: {item['answer'][:50]}{'...' if len(item['answer']) > 50 else ''}")
            print(f"   用时: {item['time_used']}")
            print()
    
    def show_help(self):
        """显示帮助信息"""
        help_text = """
🏔️ AI导游系统 - 帮助信息

基本功能:
1. 提问任何关于景区的问题
2. 系统会从知识库中查找相关信息
3. 结合DeepSeek AI生成专业回答

支持的问题类型:
- 景区基本信息（位置、历史、特色）
- 门票价格和开放时间
- 游览路线建议
- 景点详细介绍
- 交通和住宿信息
- 当地美食推荐

特殊命令:
- exit/退出: 退出系统
- voice/语音: 切换到语音输入
- text/文本: 切换到文本输入
- history/历史: 查看对话历史
- help/帮助: 显示此帮助
- clear/清空: 清空对话历史

语音功能:
- 需要安装: pip install pyttsx3 speechrecognition
- 可能需要系统音频权限
"""
        print(help_text)
    
    def save_conversation(self, filename="conversation_history.json"):
        """保存对话历史到文件"""
        try:
            with open(filename, 'w', encoding='utf-8') as f:
                json.dump(self.conversation_history, f, ensure_ascii=False, indent=2)
            print(f"✅ 对话历史已保存到 {filename}")
        except Exception as e:
            print(f"❌ 保存对话历史失败: {e}")


def main():
    """主函数"""
    print("="*60)
    print("🏔️  AI数字人导游系统 v1.0")
    print("="*60)
    
    # 创建并运行系统
    try:
        guide = AIGuideSystem()
        guide.chat_loop()
        
        # 保存对话历史
        if guide.conversation_history:
            guide.save_conversation()
            
    except Exception as e:
        print(f"❌ 系统启动失败: {e}")
        traceback.print_exc()


if __name__ == "__main__":
    main()