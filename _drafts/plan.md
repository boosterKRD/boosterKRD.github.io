✅ Modify the schema by adding new columns (cache, resource_label) to enhance functionality. - DataEgret)
	•	Add new columns to support caching and resource labels.
	•	Introduce a new index for efficient querying based on resource_type and resource_id.
✅ Refactor the application code - Sweatcoin
	•	Ensure there is only one interface for inserting new FeedItem records.
	•	Modify SQL queries to always include timestamp for optimized partition usage.
	•	Utilize the cache column to reduce redundant queries to other tables.
✅ Optimize indexing by dropping unnecessary indexes and creating efficient ones for partitioning. - DataEgret
	•	Drop old indexes that are no longer needed.
	•	Create more efficient indexes that align with the partitioning strategy.
✅ Create a partitioned table with a monthly partitioning strategy to improve query speed and data management. - DataEgret
	•	Define a new partitioned version of sweat_wallet_feed_items, partitioned by timestamp.
	•	Establish primary indexes for optimized searches and filtering.
✅ Perform a cutover by renaming the existing table, promoting the partitioned version, and ensuring a smooth transition.  - DataEgret
	•	Apply a CHECK constraint on timestamp to ensure all existing data falls within the partitioned range.
	•	Validate this constraint to prevent issues during partition attachment.
✅ Implement a partition maintenance strategy, allowing automatic partition creation and data retention management. - DataEgret
	•	Start the transaction 
    •   Lock the existing table to prevent data inconsistencies.
	•	Rename the current table to sweat_wallet_feed_items_old.
	•	Rename the partitioned table to sweat_wallet_feed_items.
	•	Drop the id column from the old table (since partitioning uses a different unique index).
	•	Attach the old table as a partition to retain existing data.
	•	Commit the transaction to finalize the transition.