###
#
# BelongsTo 'user', User
#     leads to
#     user: -> @belongsTo User
#
# BelongsTo User
#     leads to
#     <User.name.toLowerCase()>: -> @belongsTo User
#
# BelongsTo 'user', User, -> @where(username: 'foo')
#     leads to
#     user: -> relation = @belongsTo(User); f.call(relation)
#
# class User extends db.Model
#     tableName: 'users'
#     @schema [
#         HasMany Photo
#     ]
#
# class Photo extends db.Model
#     tableName: 'photos'
#     @schema [
#         BelongsTo User
#     ]
#
# Photo.forge(id: 1).fetch(withRelated: 'user').then (photo) ->
#     photo.user                              # function
#     photo.related('user')                   # Collection
#     photo.$user                             # Collection
#     photo.$user.assign(user)                # set user_id to user.id and save
#
# User.forge(id: 1).fetch(withRelated: 'photos').then (user) ->
#     user.photos                             # function
#     user.related('photos')                  # Collection
#     user.$photos                            # Collection
#     user.$photos.assign(...)                # detach all photos and attach listed
#     user.$photos.attach(...)                # attach listed photos and save them
#     user.$photos.detach(...)                # detach listed photos
#
# class User extends db.Model
#     tableName: 'users'
#     @schema [
#         HasMany Photo, onDestroy: (cascade|cascade direct|detach|detach direct|reject|ignore)
#     ]
#
###

pluralize = require 'pluralize'
{IntField} = require './fields'
{Fulfilled, Rejected, promiseFinally, values, pluck, upperFirst} = require './utils'

class Relation
    @multiple: false

    constructor: (model, options = {}) ->
        return new Relation(arguments...) unless this instanceof Relation
        @relatedModel = model
        @options = options
        @name = @_deduceName(@relatedModel)

    pluginOption: (name, defaultVal) -> @model.__bookshelf_schema_options[name] or defaultVal
    option: (name, pluginOptionName, defaultVal) ->
        if arguments.length is 2
            defaultVal = pluginOptionName
            pluginOptionName = name
        value = @options[name]
        value = @pluginOption(pluginOptionName, defaultVal) unless value?
        value
    contributeToSchema: (schema) -> schema.push this
    contributeToModel: (cls) ->
        @model = cls
        @accessor = @options.accessor || @_deduceAccessorName(@name)
        cls::[@name] = @createRelation(cls) unless @name of cls.prototype
        if @option('createProperty', 'createProperties', true)
            @_createProperty(cls)

    createRelation: (cls) ->
        relation = @_createRelation(cls)
        relation = @_applyQuery(relation)
        relation = @_applyThrough(relation)

        self = this
        -> self._augementRelated this, relation.apply(this, arguments)

    createGetter: ->
        self = this
        ->
            related = @related(self.name)
            unless related.__augemented
                self._augementRelated this, related
            related

    createSetter: ->

    # TODO: apply withPivot
    # TODO: auto-discover withPivot columns from through models schema
    _applyThrough: (builder) ->
        return builder unless @options.through
        interim = @options.through
        throughForeignKey = @options.throughForeignKey
        otherKey = @options.otherKey
        -> builder.call(this).through(interim, throughForeignKey, otherKey)

    _applyQuery: (builder) ->
        return builder unless @options.query
        query = @options.query
        -> query.apply builder.call(this)

    _augementRelated: (parent, related) ->
        return related unless @constructor.helperMethods
        self = this
        for name, method of @constructor.helperMethods
            do (method) ->
                if name of related
                    related["_original#{upperFirst(name)}"] = related[name]
                related[name] = (args...) ->
                    args = [parent, self].concat args
                    method.apply this, args
        related.__augemented = true
        related

    _createProperty: (cls) ->
        return if @name is 'id' or @accessor of cls.prototype
        spec = {}
        getter = @createGetter()
        setter = @createSetter()
        spec.get = getter if getter
        spec.set = setter if setter

        Object.defineProperty cls.prototype, @accessor, spec

    _deduceName: ->
        return @options.name if @options.name?
        if @constructor.multiple
            pluralize @relatedModel.name.toLowerCase()
        else
            @relatedModel.name.toLowerCase()

    _deduceAccessorName: -> "#{@pluginOption('relationAccessorPrefix', '$')}#{@name}"

    _forceTransaction: (options, callback) ->
        options ?= {}
        t = if options.transacting
            options.transacting.transaction
        else
            @model.transaction

        t (trx) ->
            oldTtransacting = options.transacting
            options.transacting = trx
            promiseFinally callback(options), ->
                options.transacting = oldTtransacting

class HasOne extends Relation
    constructor: (model, options = {}) ->
        return new HasOne(arguments...) unless this instanceof HasOne
        super

    @helperMethods: require './relations/has_one'

    _createRelation: (cls) ->
        related = @relatedModel
        foreignKey = @options.foreignKey
        -> @hasOne related, foreignKey

class BelongsTo extends Relation
    constructor: (model, options = {}) ->
        return new BelongsTo(arguments...) unless this instanceof BelongsTo
        super

    contributeToSchema: (schema) ->
        super
        schema.push IntField "#{@name}_id"

    @helperMethods: require './relations/belongs_to'

    _createRelation: (cls) ->
        related = @relatedModel
        foreignKey = @options.foreignKey
        -> @belongsTo related, foreignKey

    # Patch returned relations joinClauses and whereClauses
    # TODO: apply withPivot
    # TODO: auto-discover withPivot columns from through models schema
    _applyThrough: (builder) ->
        return builder unless @options.through
        interim = @options.through
        throughForeignKey = @options.throughForeignKey
        otherKey = @options.otherKey
        ->
            relation = builder.call(this).through(interim, throughForeignKey, otherKey)
            relation.relatedData.joinClauses = BelongsTo._patchedJoinClauses
            relation.relatedData.whereClauses = BelongsTo._patchedWhereClauses
            relation

    @_patchedJoinClauses: (knex) ->
        joinTable = @joinTable()
        targetKey = @key('foreignKey')

        knex.join \
            joinTable,
            joinTable + '.' + targetKey, '=',
            @targetTableName + '.' + @targetIdAttribute

        knex.join \
            "#{@parentTableName} as __parent",
            "#{joinTable}.#{@throughIdAttribute}", '=',
            "__parent.#{@key('throughForeignKey')}"

    @_patchedWhereClauses: (knex, resp) ->
        key = "__parent.#{@parentIdAttribute}"
        knex[if resp then 'whereIn' else 'where'](key, if resp then @eagerKeys(resp) else @parentFk)

class HasMany extends Relation
    @multiple: true

    constructor: (model, options = {}) ->
        return new HasMany(arguments...) unless this instanceof HasMany
        super

    @helperMethods: require './relations/has_many'

    _createRelation: (cls) ->
        related = @relatedModel
        foreignKey = @options.foreignKey
        -> @hasMany related, foreignKey

class BelongsToMany extends Relation
    @multiple: true

    constructor: (model, options = {}) ->
        return new BelongsToMany(arguments...) unless this instanceof BelongsToMany
        super

    @helperMethods: require './relations/belongs_to_many'

    _createRelation: (cls) ->
        related = @relatedModel
        table = @options.table
        foreignKey = @options.foreignKey
        otherKey = @options.otherKey
        -> @belongsToMany related, table, foreignKey, otherKey

class MorphOne extends Relation
    constructor: (model, polymorphicName, options = {}) ->
        return new MorphOne(arguments...) unless this instanceof MorphOne
        super model, options
        @polymorphicName = polymorphicName

    @helperMethods: require './relations/morph_one'

    _createRelation: (cls) ->
        related = @relatedModel
        name = @polymorphicName
        columnNames = @options.columnNames
        morphValue = @options.morphValue
        -> @morphOne related, name, columnNames, morphValue

class MorphMany extends Relation
    @multiple: true

    constructor: (model, polymorphicName, options = {}) ->
        return new MorphMany(arguments...) unless this instanceof MorphMany
        super model, options
        @polymorphicName = polymorphicName

    @helperMethods: require './relations/morph_many'

    _createRelation: (cls) ->
        related = @relatedModel
        name = @polymorphicName
        columnNames = @options.columnNames
        morphValue = @options.morphValue
        -> @morphMany related, name, columnNames, morphValue

class MorphTo extends Relation
    constructor: (polymorphicName, targets, options = {}) ->
        return new MorphTo(arguments...) unless this instanceof MorphTo
        options.name = polymorphicName
        super targets, options
        @polymorphicName = polymorphicName

    @helperMethods: require './relations/morph_to'

    _createRelation: (cls) ->
        args = [@polymorphicName]
        args.push @options.columnNames if @options.columnNames
        args = args.concat @relatedModel
        -> @morphTo args...

module.exports =
    HasOne: HasOne
    BelongsTo: BelongsTo
    HasMany: HasMany
    BelongsToMany: BelongsToMany
    MorphOne: MorphOne
    MorphMany: MorphMany
    MorphTo: MorphTo
