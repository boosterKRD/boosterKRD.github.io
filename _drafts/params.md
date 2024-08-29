maintenance_work_mem = (total_memory - shared_buffers) / (max_connections * 5)
work_mem = MIN(total_memory / (2 * max_connections), 32MB)
shared_buffers = total_memory * 0.25
effective_cache_size = (total_memory - shared_buffers) * 0.9



