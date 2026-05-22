module LLMProxy
  Config = Struct.new(
    :server, :models, keyword_init: true
  ) do
    def self.load(path)
      raw = YAML.safe_load_file(File.expand_path(path), permitted_classes: [Symbol])
      new(
        server: (raw["server"] || {}).transform_keys(&:to_sym),
        models: (raw["models"] || []).map { |m| ModelConfig.new(**m.transform_keys(&:to_sym)) }
      )
    end
  end

  ModelConfig = Struct.new(
    :id, :provider, :display_name, :api_key,
    :context_window, :max_tokens, :capabilities,
    keyword_init: true
  ) do
    def capabilities
      self[:capabilities] || []
    end

    def supports?(cap)
      capabilities.include?(cap.to_s)
    end
  end
end
