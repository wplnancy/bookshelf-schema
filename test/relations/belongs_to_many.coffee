Bookshelf = require 'bookshelf'
Schema = require '../../src/'
init = require '../init'
Fields = require '../../src/fields'
Relations = require '../../src/relations'

{StringField} = Fields
{HasMany, BelongsToMany} = Relations

describe "Relations", ->
    this.timeout 3000
    db = null
    User = null
    Group = null

    fixtures =
        alice: ->
            new User(username: 'alice').save()
        groups: (names...) ->
            names.map (name) ->
                new Group(name: name).save()
        connect: (user, groups) ->
            groups.map (group) ->
                db.knex('groups_users').insert(user_id: user.id, group_id: group.id)

    before co ->
        db = init.init()
        yield [ init.users(), init.groups() ]

    describe 'BelongsToMany', ->
        beforeEach ->
            class Group extends db.Model
                tableName: 'groups'

            class User extends db.Model
                tableName: 'users'
                @schema [
                    StringField 'username'
                    BelongsToMany Group
                ]

            Group.schema [
                StringField 'name'
                BelongsToMany User
            ]

        afterEach co ->
            yield (db.knex(table).truncate() for table in ['users', 'groups', 'groups_users'])

        it 'creates accessor', co ->
            [alice, groups] = yield [ fixtures.alice(), fixtures.groups('users') ]
            yield fixtures.connect alice, groups
            alice.groups.should.be.a 'function'
            yield alice.load 'groups'
            alice.$groups.should.be.an.instanceof db.Collection
            alice.$groups.at(0).name.should.equal 'users'

        it 'can assign list of models to relation', co ->
            [alice, [users, music, games]] = yield [
                fixtures.alice()
                fixtures.groups('users', 'music', 'games')
            ]
            yield fixtures.connect alice, [users, music]
            yield alice.$groups.assign [games, music]

            alice = yield User.forge(id: alice.id).fetch(withRelated: 'groups')

            alice.$groups.pluck('name').sort().should.deep.equal ['games', 'music']

        it 'can also assign plain objects and ids', co ->
            [alice, [users]] = yield [
                fixtures.alice()
                fixtures.groups('users')
            ]

            yield alice.$groups.assign [users.id, {name: 'games'}]
            alice = yield User.forge(id: alice.id).fetch(withRelated: 'groups')

            alice.$groups.pluck('name').sort().should.deep.equal ['games', 'users']

        it 'detach all related objects when empty list assigned', co ->
            [alice, [users]] = yield [
                fixtures.alice()
                fixtures.groups('users')
            ]
            yield fixtures.connect alice, [users]

            alice = yield User.forge(id: alice.id).fetch(withRelated: 'groups')
            alice.$groups.length.should.equal 1

            yield alice.$groups.assign []

            alice = yield User.forge(id: alice.id).fetch(withRelated: 'groups')
            alice.$groups.length.should.equal 0
