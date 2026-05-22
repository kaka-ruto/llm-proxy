module LLMProxy
  class ModelCatalog
    def initialize(config)
      @models = {}
      @by_slug = {}

      config.models.each do |m|
        @models[m.id] = m
        slug = m.id.gsub(/[^a-zA-Z0-9]+/, "-").downcase
        @by_slug[slug] = m unless slug == m.id
      end
    end

    def lookup(id)
      @models[id] || @by_slug[id]
    end

    def all
      @models.values
    end

    def to_openai_list
      all.map do |m|
        {
          id: m.id,
          object: "model",
          created: Time.now.to_i,
          owned_by: m.provider
        }
      end
    end
  end
end
