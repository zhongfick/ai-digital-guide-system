# cache_manager.py
# Redis 缓存管理器 - 支持持久化缓存

import redis.asyncio as aioredis
import json
import asyncio
from typing import Optional, Any, Dict, List
from datetime import datetime, timedelta
import logging

logger = logging.getLogger(__name__)


class CacheManager:
    """异步 Redis 缓存管理器"""
    
    def __init__(self, redis_url: str = "redis://localhost:6379", default_ttl: int = 3600):
        """
        初始化缓存管理器
        
        Args:
            redis_url: Redis 连接字符串，默认本地 Redis
            default_ttl: 默认缓存过期时间（秒），默认 1 小时
        """
        self.redis_url = redis_url
        self.default_ttl = default_ttl
        self.redis = None
        self.connected = False
    
    async def connect(self):
        """连接到 Redis"""
        try:
            self.redis = await aioredis.from_url(self.redis_url, decode_responses=True, socket_connect_timeout=3)
            # 测试连接
            await self.redis.ping()
            self.connected = True
            logger.info("✅ Redis 缓存连接成功")
            return True
        except Exception as e:
            logger.warning(f"⚠️ Redis 连接失败: {e}，缓存功能不可用")
            self.connected = False
            self.redis = None
            return False
    
    async def disconnect(self):
        """断开 Redis 连接"""
        if self.redis:
            await self.redis.close()
            self.connected = False
            logger.info("Redis 缓存连接已关闭")
    
    async def get(self, key: str) -> Optional[Any]:
        """获取缓存值"""
        if not self.connected:
            return None
        
        try:
            value = await self.redis.get(key)
            if value:
                return json.loads(value)
            return None
        except Exception as e:
            logger.error(f"❌ 获取缓存失败 [{key}]: {e}")
            return None
    
    async def set(self, key: str, value: Any, ttl: Optional[int] = None) -> bool:
        """设置缓存值"""
        if not self.connected:
            return False
        
        try:
            ttl = ttl or self.default_ttl
            await self.redis.setex(key, ttl, json.dumps(value, ensure_ascii=False))
            logger.debug(f"✓ 缓存已设置 [{key}]，TTL: {ttl}s")
            return True
        except Exception as e:
            logger.error(f"❌ 设置缓存失败 [{key}]: {e}")
            return False
    
    async def delete(self, key: str) -> bool:
        """删除缓存"""
        if not self.connected:
            return False
        
        try:
            await self.redis.delete(key)
            logger.debug(f"✓ 缓存已删除 [{key}]")
            return True
        except Exception as e:
            logger.error(f"❌ 删除缓存失败 [{key}]: {e}")
            return False
    
    async def clear_pattern(self, pattern: str) -> int:
        """删除匹配模式的所有缓存"""
        if not self.connected:
            return 0
        
        try:
            keys = await self.redis.keys(pattern)
            if keys:
                deleted = await self.redis.delete(*keys)
                logger.info(f"✓ 删除了 {deleted} 个缓存 (模式: {pattern})")
                return deleted
            return 0
        except Exception as e:
            logger.error(f"❌ 清除缓存模式失败 [{pattern}]: {e}")
            return 0
    
    async def flush_all(self) -> bool:
        """清空所有缓存"""
        if not self.connected:
            return False
        
        try:
            await self.redis.flushdb()
            logger.warning("✓ 所有缓存已清空")
            return True
        except Exception as e:
            logger.error(f"❌ 清空缓存失败: {e}")
            return False
    
    async def get_stats(self) -> Dict[str, Any]:
        """获取缓存统计信息"""
        if not self.connected:
            return {"status": "disconnected"}
        
        try:
            info = await self.redis.info()
            keys = await self.redis.dbsize()
            return {
                "status": "connected",
                "total_keys": keys,
                "memory_used": info.get("used_memory_human", "N/A"),
                "redis_version": info.get("redis_version", "N/A"),
                "uptime_seconds": info.get("uptime_in_seconds", "N/A")
            }
        except Exception as e:
            logger.error(f"❌ 获取缓存统计失败: {e}")
            return {"status": "error", "error": str(e)}
    
    async def cache_response(self, cache_key: str, ttl: Optional[int] = None):
        """缓存装饰器 - 用于缓存函数返回值"""
        def decorator(func):
            async def wrapper(*args, **kwargs):
                # 尝试从缓存获取
                cached_value = await self.get(cache_key)
                if cached_value is not None:
                    logger.debug(f"缓存命中 [{cache_key}]")
                    return cached_value
                
                # 执行函数
                result = await func(*args, **kwargs) if asyncio.iscoroutinefunction(func) else func(*args, **kwargs)
                
                # 存入缓存
                await self.set(cache_key, result, ttl)
                return result
            
            return wrapper
        return decorator


# 全局缓存实例
_cache_manager: Optional[CacheManager] = None


async def init_cache(redis_url: str = "redis://localhost:6379", default_ttl: int = 3600) -> CacheManager:
    """初始化全局缓存管理器"""
    global _cache_manager
    _cache_manager = CacheManager(redis_url, default_ttl)
    await _cache_manager.connect()
    return _cache_manager


def get_cache_manager() -> Optional[CacheManager]:
    """获取全局缓存管理器"""
    return _cache_manager


async def shutdown_cache():
    """关闭全局缓存管理器"""
    global _cache_manager
    if _cache_manager:
        await _cache_manager.disconnect()
        _cache_manager = None
