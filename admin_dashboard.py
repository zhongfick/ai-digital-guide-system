# admin_dashboard.py
import streamlit as st
import requests
import pandas as pd
import os
import json
from datetime import datetime

# 【新增代码】强制切换到你的项目根目录，确保能找到 logs 文件夹
os.chdir(r"D:\AI_Guide_Project")  # 切回项目根目录，不是 logs 文件夹

st.set_page_config(page_title="景区管理后台", layout="wide")
API = "http://10.3.163.254:8000"   # 改成你查到的真实IP

st.title("🏔️ 景区导览 — 管理后台")

tab1, tab2, tab3, tab4, tab5 = st.tabs(["📊 数据大屏", "📚 知识库管理", "🎭 数字人形象", "📝 游客反馈", "📈 感受度报告"])

# ---- Tab1 数据大屏 ----
with tab1:
    st.subheader("运营概览")
    try:
        r = requests.get(f"{API}/admin/stats/dashboard", timeout=5)
        d = r.json()
        c1, c2, c3 = st.columns(3)
        c1.metric("今日对话数", d["today_chats"])
        c2.metric("知识库文档数", d["knowledge_count"])
        c3.metric("系统状态", "🟢 正常")

        st.subheader("🔥 热门问题 TOP5")
        if d["hot_questions"]:
            df_hot = pd.DataFrame(d["hot_questions"])
            st.bar_chart(df_hot.set_index("q"))

        else:
            st.info("今日暂无对话记录")
    except Exception as e:
        st.error(f"获取统计数据失败: {e}")

# ---- Tab2 知识库管理 ----
with tab2:
    st.subheader("上传景区知识文档")
    uploaded = st.file_uploader("选择文件（txt / docx / pdf）", type=["txt","docx","pdf"])
    cat = st.selectbox("分类", ["general","景点介绍","历史文化","FAQ"])
    if st.button("上传并重建索引") and uploaded:
        files = {"file": (uploaded.name, uploaded.getvalue())}
        data = {"category": cat}
        r = requests.post(f"{API}/admin/knowledge/upload", files=files, data=data)
        st.success(f"上传成功：{r.json()}")

    st.divider()
    st.subheader("已有知识文档")
    try:
        docs = requests.get(f"{API}/admin/knowledge/list").json()["files"]
        if docs:
            st.table(pd.DataFrame(docs))
        else:
            st.info("暂无文档，请上传")
    except:
        st.warning("无法连接后端，请确认服务运行中")

# ---- Tab3 数字人形象 ----
with tab3:
    st.subheader("数字人形象配置")
    voice = st.selectbox("语音音色", ["female_cn", "male_cn", "female_en"])
    outfit = st.selectbox("服装风格", ["traditional_blue", "modern_green", "festival_red"])
    skin = st.selectbox("肤色", ["fair", "medium", "tan"])
    if st.button("💾 保存配置"):
        cfg = {"voice": voice, "outfit": outfit, "skin": skin}
        requests.post(f"{API}/admin/persona/save", json=cfg)
        st.success("形象配置已保存！")

# ---- Tab4 游客反馈 ----
with tab4:
    st.subheader("游客反馈查看")
    date_sel = st.date_input("选择日期", datetime.now())
    ds = date_sel.strftime("%Y%m%d")
    try:
        fb = requests.get(f"{API}/admin/feedback/list", params={"date": ds}).json()["feedbacks"]
        if fb:
            st.dataframe(pd.DataFrame(fb)[["question","answer","rating"]])
        else:
            st.info("该日无反馈记录")
    except:
        st.warning("无法获取反馈")

# ---- Tab5 游客感受度报告 ----
with tab5:
    st.subheader("📊 游客感受度报告")
    
    # 选择分析天数
    days = st.slider("分析最近多少天的数据", 1, 30, 7)
    
    if st.button("生成报告"):
        with st.spinner("正在分析对话记录..."):
            try:
                r = requests.get(f"{API}/admin/report/sentiment", params={"days": days}, timeout=10)
                report = r.json()
                
                if report["total_records"] == 0:
                    st.info("暂无对话记录可供分析")
                else:
                    # 显示基本信息
                    col1, col2, col3 = st.columns(3)
                    col1.metric("分析天数", f"{report['analysis_days']}天")
                    col2.metric("对话总数", report["total_records"])
                    col3.metric("报告日期", report["report_date"])
                    
                    st.divider()
                    
                    # 1. 游客关注点分析
                    st.subheader("🎯 游客关注点分析")
                    
                    attention = report["attention_analysis"]
                    
                    col1, col2 = st.columns(2)
                    
                    with col1:
                        st.write("**热门关键词 TOP10**")
                        if attention["top_keywords"]:
                            kw_df = pd.DataFrame(attention["top_keywords"])
                            st.bar_chart(kw_df.set_index("word"))
                        else:
                            st.info("暂无数据")
                    
                    with col2:
                        st.write("**话题分布**")
                        if attention["topic_distribution"]:
                            topic_df = pd.DataFrame(attention["topic_distribution"])
                            st.bar_chart(topic_df.set_index("topic"))
                        else:
                            st.info("暂无数据")
                    
                    st.divider()
                    
                    # 2. 情感分析
                    st.subheader("💭 情感分析")
                    
                    sentiment = report["sentiment_analysis"]
                    overall = sentiment["overall"]
                    
                    col1, col2, col3 = st.columns(3)
                    col1.metric("正面评价", f"{overall['positive']}条", f"{overall['positive_rate']}%")
                    col2.metric("中性评价", f"{overall['neutral']}条")
                    col3.metric("负面评价", f"{overall['negative']}条")
                    
                    # 情感趋势图
                    st.write("**最近情感趋势**")
                    if sentiment["trend"]:
                        trend_data = []
                        for s in sentiment["trend"]:
                            score = 1 if s["sentiment"] == "positive" else (-1 if s["sentiment"] == "negative" else 0)
                            trend_data.append({"时间": s["timestamp"][11:19] if s["timestamp"] else "", "情感分数": score})
                        
                        if trend_data:
                            trend_df = pd.DataFrame(trend_data)
                            st.line_chart(trend_df.set_index("时间"))
                    
                    st.divider()
                    
                    # 3. 服务建议
                    st.subheader("💡 服务建议")
                    
                    suggestions = report["suggestions"]
                    for i, suggestion in enumerate(suggestions, 1):
                        st.info(f"{i}. {suggestion}")
                    
                    # 导出报告
                    st.divider()
                    if st.button("📥 导出报告"):
                        report_json = json.dumps(report, ensure_ascii=False, indent=2)
                        st.download_button(
                            label="下载 JSON 报告",
                            data=report_json,
                            file_name=f"sentiment_report_{report['report_date']}.json",
                            mime="application/json"
                        )
                        
            except Exception as e:
                st.error(f"生成报告失败: {e}")