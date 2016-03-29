###
# Copyright 2015 IBM Corp. All Rights Reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
###


TwitterClient = require 'twitter'
Promise = require 'bluebird'
_ = require 'underscore'
isArray = _.isArray
extend = _.extendOwn
logger = require 'winston'

MAX_COUNT = 200

isInt = (value) ->
  !isNaN(value) and parseInt(Number(value)) == value and not isNaN(parseInt(value, 10))

errorCode = (error) -> error.code || (if error[0] then error[0].code else 0)

enabled = (credentials) -> credentials.filter((c) => c.enabled)

class TwitterCrawler

  constructor: (credentials, options = {}) ->
    this.setOptions(options)
    this.count = 0
    this.createClients(credentials)

  validateCredentials: (credentials) ->
    if !credentials || (isArray(credentials) && enabled(credentials).length == 0)
      throw new Error 'You must provide valid credentials'


  createClients: (credentials) ->
    this.clients = []
    this.validateCredentials credentials
    enabled(credentials)
      .forEach (credential) =>
        client = new TwitterClient(credential)
        client._instance_id = this.clients.length
        client._valid = true
        this.clients.push(client)

  setOptions: (options) ->
    this.options = extend({
        debug : false
      }, options)

  getInstance: ->
    instanceIndex = this.count % this.clients.length
    attempt = 1
    this.count++

    while !this.clients[instanceIndex]._valid && attempt <= this.clients.length
      attempt +=1
      this.count++

    if attempt > this.clients.length
      throw new Error 'All instances are invalid! Review your credentials.'
    else
      logger.debug('Using twitter credentials nº' + instanceIndex);
      this.clients[instanceIndex]

  callApi: (method, args...) ->
    if not (method in ['get', 'post'])
      throw new Error 'Method \'' + method + '\' not implemented.'

    new Promise (resolve, reject) =>
        instance = this.getInstance()

        callback = (err, data) =>
          if err
            errorMessage = 'Error calling \'' + args[0] + '\' api ' +
              '['+ method.toUpperCase() + '] on instance ' + instance._instance_id + '.'

            if errorCode(err) == 32
              # Try again with a different instance
              errorMessage += ' Error code: ' + errorCode(err) + '.'
              logger.error errorMessage, 'Using another instance.', err
              this.callApi(method, args...)
            if errorCode(err) == 89
              errorMessage += ' Error code: ' + errorCode(err) + '.'
              # Try again with a different instance & disabling
              instance._valid = false
              instance._error = err
              logger.error errorMessage, 'Using another instance.', err
              this.callApi(method, args...)
            else
              # Abort
              logger.error errorMessage
              logger.error err
              reject err
          else
            resolve data

        instance[method](args.concat([callback])...)

  get: (args...) ->
    this.callApi('get', args...)

  post: (args...) ->
    this.callApi('post', args...)

  _getTweets: (params, options, accumulatedTweets = []) ->
    # Performs tweets crawling
    new Promise (resolve, reject) =>
      # Crawler function
      crawler = (incomingTweets) =>
        logger.debug(
            'Obtained', incomingTweets.length, 'for userId',
            params.user_id + '.', 'Total tweets for user:',
            incomingTweets.length + accumulatedTweets.length
          )
        limitReached = options.limit and (accumulatedTweets.length + incomingTweets.length) > options.limit
        if incomingTweets.length > 1 and not limitReached
          # Got tweets? Let's see if there more out there
          this._getTweets(
              extend(params, maxId : incomingTweets[incomingTweets.length-1].id - 1),
              options
              accumulatedTweets.concat(incomingTweets)
            ).done(resolve, reject)
        else
          output = accumulatedTweets.concat(incomingTweets)
          if options.limit
            output = output[0..options.limit]
          resolve output

      # Get tweets
      this.get('statuses/user_timeline', params)
        .done(crawler, reject)

  getTweets: (userId, options = {}) ->
    params =
      user_id: (userId if isInt userId)
      screen_name: (userId.replace('@', '') if not (isInt userId))
      count: MAX_COUNT
      exclude_replies: true
      trim_user: true
      maxId: undefined
    this._getTweets params, options

  getUser: (userId) ->
    params =
      user_id: (userId if isInt userId)
      screen_name: (userId.replace('@', '') if not (isInt userId))

    this.get('users/show', params)

module.exports = TwitterCrawler
