using System;
using System.Text.Json.Serialization;

namespace DeskIsle.Models
{
    public class TodoItem
    {
        [JsonPropertyName("id")]
        public string Id { get; set; } = Guid.NewGuid().ToString();

        [JsonPropertyName("text")]
        public string Text { get; set; } = string.Empty;

        [JsonPropertyName("completed")]
        public bool Completed { get; set; }

        [JsonPropertyName("priority")]
        public string Priority { get; set; } = "medium"; // high, medium, low

        [JsonIgnore]
        public string PriorityColor => Priority switch
        {
            "high" => "#EF4444",   // 红 (high)
            "medium" => "#F59E0B", // 橙 (medium)
            _ => "#888888"         // 灰 (low, 与 mac 端 secondary 统一)
        };
    }
}
