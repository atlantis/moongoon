# :nodoc:
module Moongoon::Traits::Database::Internal
  extend self

  # Utilities #

  def bson_id(id : String | BSON::ObjectId | Nil)
    case id
    when String
      BSON::ObjectId.new id
    when BSON::ObjectId
      id
    when Nil
      nil
    end
  end

  # Query builders #

  protected def self.format_aggregation(query, stages, fields = nil, order_by = nil, skip = 0, limit : Int32? = 0)
    pipeline = query && !query.empty? ? [
      BSON.new({"$match": BSON.new(query)}),
    ] : [] of BSON

    stages.each { |stage|
      pipeline << BSON.new(stage)
    }
    if fields
      pipeline << BSON.new({"$project": BSON.new(fields)})
    end
    if order_by
      {{ debug() }}
      pipeline << BSON.new({"$sort": BSON.new(order_by)})
    end
    if skip > 0
      pipeline << BSON.new({"$skip": skip.to_i32})
    end
    if (limit_i32 = limit) && limit_i32 > 0
      pipeline << BSON.new({"$limit": limit_i32})
    end
    pipeline
  end

  protected def self.concat_id_filter(query, id : BSON::ObjectId | String | Nil)
    BSON.new({"_id": self.bson_id(id)}).append(BSON.new(query))
  end

  protected def self.concat_ids_filter(query, ids : Array(BSON::ObjectId?) | Array(String?))
    BSON.new({
      "_id" => {
        "$in" => ids.map { |id|
          self.bson_id(id)
        }.compact,
      },
    }).append(BSON.new(query))
  end

  # Validation helpers #

  # Raises if the Model has a nil id field.
  private def id_check!
    raise ::Moongoon::Error::NotFound.new unless self._id
  end
end
