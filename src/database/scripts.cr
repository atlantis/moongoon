# This module handles database migration scripts.
module Moongoon::Database::Scripts
  SCRIPT_CLASSES = [] of Class

  # Scripts inherit from this class.
  #
  # ### Example
  #
  # ```
  # class Moongoon::Database::Scripts::Test < Moongoon::Database::Scripts::Base
  #   # Scripts run in ascending order.
  #   # Default order if not specified is 1.
  #   order Time.utc(2020, 3, 11).to_unix
  #
  #   # Use :retry to retry the script next time moongoon connects if the script raises.
  #   on_error :discard
  #
  #   def process(db : Mongo::Database)
  #     # Dummy code that will add a ban flag for users that are called 'John'.
  #     # This code uses the `mongo.cr` driver shard syntax, but Models could
  #     # be used for convenience despite a performance overhead.
  #     db["users"].update(
  #       selector: {name: "John"},
  #       update: {"$set": {"banned": true}},
  #       flags: LibMongoC::UpdateFlags::MULTI_UPDATE
  #     )
  #   end
  # end
  # ```
  #
  # ### Usage
  #
  # **Any class that inherits from `Moongoon::Database::Scripts::Base` will be registered as a script.**
  #
  # Scripts are run when calling `Moongoon::Database.connect` and after a successful database connection.
  # They are run a single time and the outcome is be written in the `scripts` collection.
  #
  # If multiple instances of the server are started simultaneously they will wait until all the scripts
  # are processed before resuming execution.
  abstract class Base

    # The order in which the scripts are run.
    class_property order : Int64 = 1
    # The action to perform on failure.
    # Set to *:retry* to run the script again the next time the program starts.
    class_property on_error : Action = :discard
    # The action to perform on success.
    # Set to *:retry* to run the script again the next time the program starts.
    class_property on_success : Action = :discard

    # Action to perform when a script fails.
    enum Action
      Discard
      Retry
    end

    # Will be executed once after a successful database connection and
    # if it has never been run against the target database before.
    abstract def process(db : Mongo::Database)

    macro inherited
      {% verbatim do %}
        {% Moongoon::Database::Scripts::SCRIPT_CLASSES << @type %}

        private macro order(nb)
          @@order : Int64 = {{nb}}
        end

        private macro on_error(action)
          @@on_error : Action = {{action}}
        end

        private macro on_success(action)
          @@on_success : Action = {{action}}
        end

        # Process a registered script.
        def self.process(db : Mongo::Database)
          script_class_name = {{ @type.stringify }}

          script = db["scripts"].find_one({ name: script_class_name }.to_bson, fields: { retry: 1 }.to_bson)
          if script
            return unless script.try &.["retry"]?
            db["scripts"].remove({ name: script_class_name }.to_bson)
          end

          ::Moongoon::Log.info { "Running script '#{script_class_name}'" }

          db["scripts"].insert({ name: script_class_name, date: Time.utc.to_rfc3339, status: "running" }.to_bson)
          {{ @type }}.new.process(db)
          db["scripts"].update({ name: script_class_name }.to_bson, { "$set": { status: "done", retry: @@on_success == Action::Retry } }.to_bson)
        rescue e
          ::Moongoon::Log.error { "Error while running script '#{script_class_name}'\n#{e.message.to_s}" }
          db["scripts"].update(
            { name: script_class_name }.to_bson,
            { "$set": { status: "error", error: e.message.to_s, retry: @@on_error == Action::Retry }}.to_bson
          )
        end
      {% end %}
    end
  end

  # :nodoc:
  # Process every registered script.
  #
  # For each registered script the following steps will be executed:
  #
  # - Perform a lookup in the `scripts` collection to check whether the script has already been executed.
  # - If not, then attempt to run it.
  # - If another process is running the script already, will wait for completion and resume execution.
  # - Log the result of the script in the database and go on.
  def self.process
    ::Moongoon::Log.info { "Processing database scripts…" }
    callbacks = [] of {Int64, Proc(Mongo::Database, Nil)}
    {% for script in SCRIPT_CLASSES %}
      callbacks << { {{script}}.order, ->{{script}}.process(Mongo::Database) }
    {% end %}
    callbacks.sort! { |a, b| a[0] <=> b[0] }
    callbacks.each { |_, cb|
      ::Moongoon.connection_with_lock "scripts" { |db|
        cb.call(db)
      }
    }
  end
end
