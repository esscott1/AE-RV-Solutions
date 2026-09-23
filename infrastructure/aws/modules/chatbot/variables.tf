variable "name_prefix" {
  description = "Prefix for every resource name. The CI roles' chatbot permissions (bootstrap/chatbot.tf) are scoped to it, so the two must match."
  type        = string
  default     = "ae-rv-chatbot"
}

variable "inference_profile_id" {
  description = "Bedrock inference profile the chatbot calls. Claude Haiku 4.5 is only offered through inference profiles; the us. profile keeps inference in US regions."
  type        = string
  default     = "us.anthropic.claude-haiku-4-5-20251001-v1:0"
}

variable "foundation_model_id" {
  description = "Foundation model behind inference_profile_id. IAM must allow it in every region the profile routes to."
  type        = string
  default     = "anthropic.claude-haiku-4-5-20251001-v1:0"
}

variable "inference_profile_regions" {
  description = "Regions the inference profile routes to (aws bedrock get-inference-profile)."
  type        = list(string)
  default     = ["us-east-1", "us-east-2", "us-west-2"]
}

variable "daily_quota" {
  description = "Maximum chat requests per day, across all visitors. Once reached, the API answers 429 and the widget shows a 'busy' message until the next day."
  type        = number
  default     = 50
}

variable "throttle_rate_limit" {
  description = "Steady-state chat requests per second allowed across all visitors."
  type        = number
  default     = 1
}

variable "throttle_burst_limit" {
  description = "Chat request burst allowed across all visitors."
  type        = number
  default     = 3
}

variable "max_messages" {
  description = "Maximum messages (customer + assistant) per request. Caps both cost and how much a single conversation can extract."
  type        = number
  default     = 8
}

variable "max_user_message_chars" {
  description = "Maximum characters in one customer message."
  type        = number
  default     = 500
}

variable "max_assistant_message_chars" {
  description = "Maximum characters in one assistant message echoed back as conversation history (an answer is at most answer_max_tokens long)."
  type        = number
  default     = 2500
}

variable "answer_max_tokens" {
  description = "Output cap for an answer."
  type        = number
  default     = 600
}

variable "spike_alarm_threshold" {
  description = "Chat requests within one hour that trigger the usage-spike email to the owner."
  type        = number
  default     = 25
}

variable "owner_alerts_topic_name" {
  description = "SNS topic (created in bootstrap) that receives owner alerts."
  type        = string
  default     = "ae-rv-owner-alerts"
}

variable "tags" {
  description = "Tags applied to every taggable resource."
  type        = map(string)
  default     = {}
}

variable "embedding_model_id" {
  description = "Bedrock embedding model for the knowledge base. Changing it means re-embedding everything (recreate the index and re-sync)."
  type        = string
  default     = "amazon.titan-embed-text-v2:0"
}

variable "embedding_dimensions" {
  description = "Vector size the embedding model produces and the S3 Vectors index stores (Titan Text Embeddings V2: 1024)."
  type        = number
  default     = 1024
}

variable "kb_num_results" {
  description = "Most knowledge-base passages retrieved per answer. Kept small: enough context to answer, and too little for anyone to pull the library out in bulk."
  type        = number
  default     = 4
}

variable "kb_min_score" {
  description = "Minimum relevance score (0-1) for a retrieved passage to reach the model. Filters out weak matches that would pull unrelated content into answers. eval/answers.py prints scores for tuning."
  type        = number
  default     = 0.4
}
