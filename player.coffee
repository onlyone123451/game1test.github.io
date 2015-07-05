# Player:
#  @gl: WebGLContext
#  @audio: AudioContext
#  @input: custom class, see Input for implementation
#  @core: retro.Core
#  @game: buffer of game data or path
#  @save: buffer of save data (optional)
module.exports = class Player
  variables: {}
  variablesUpdate: false
  overscan: false
  running: false

  constructor: (@gl, @audio, @inputs, @core, @game, @save) ->
    @initGL()
    @core.PIXEL_FORMAT_0RGB1555 = 0 # should be accessible in @core
    @core.PIXEL_FORMAT_XRGB8888 = 1
    @core.PIXEL_FORMAT_RGB565 = 2
    @pixelFormat = @core.PIXEL_FORMAT_0RGB1555

    @core.video_refresh = @video_refresh
    @core.input_state = @input_state
    @core.audio_sample_batch = @audio_sample_batch
    @core.environment = @environment
    @core.input_poll = ->

    @core.init()

    @info = @core.get_system_info()
    @core.load_game
      data: @game
    @core.unserialize @save if @save?
    @av_info = @core.get_system_av_info()
    @fpsInterval = 1000 / @av_info.timing.fps

    # audio
    @then = 0
    @sampleRate = @av_info.timing.sample_rate
    @bufferSize = 256
    @latency = 96
    @numBuffers = Math.floor @latency * @sampleRate / (1000 * @bufferSize)
    if @numBuffers < 2
      @numBuffers = 2
    i = 0
    @buffers = []
    while i < @numBuffers
      @buffers[i] = @audio.createBuffer 2, @bufferSize, @sampleRate
      i++
    @bufOffset = 0
    @bufIndex = 0

  initGL: ->
    fragmentShader = @gl.createShader @gl.FRAGMENT_SHADER
    @gl.shaderSource fragmentShader, '
    precision mediump float;
    uniform sampler2D u_image;
    varying vec2 v_texCoord;
    void main() {
      gl_FragColor = texture2D(u_image, v_texCoord);
    }
    '
    @gl.compileShader fragmentShader

    vertexShader = @gl.createShader @gl.VERTEX_SHADER
    @gl.shaderSource vertexShader, '
    attribute vec2 a_texCoord;
    attribute vec2 a_position;
    varying vec2 v_texCoord;
    void main() {
      gl_Position = vec4(a_position, 0, 1);
      v_texCoord = a_texCoord;
    }
    '
    @gl.compileShader vertexShader

    program = @gl.createProgram()
    @gl.attachShader program, vertexShader
    @gl.attachShader program, fragmentShader
    @gl.linkProgram program
    @gl.useProgram program

    positionLocation = @gl.getAttribLocation program, 'a_position'
    buffer = @gl.createBuffer()
    @gl.bindBuffer @gl.ARRAY_BUFFER, buffer

    @gl.bufferData @gl.ARRAY_BUFFER, (new Float32Array [
      -1, -1,
      1, -1,
      -1, 1,
      -1, 1,
      1, -1,
      1, 1
    ]), @gl.STATIC_DRAW
    @gl.enableVertexAttribArray positionLocation
    @gl.vertexAttribPointer positionLocation, 2, @gl.FLOAT, false, 0, 0

    texCoordLocation = @gl.getAttribLocation program, 'a_texCoord'
    texCoordBuffer = @gl.createBuffer()
    @gl.bindBuffer @gl.ARRAY_BUFFER, texCoordBuffer

    @gl.bufferData @gl.ARRAY_BUFFER, (new Float32Array [
      0, 0,
      1, 0,
      0, 1,
      0, 1,
      1, 0,
      1, 1
    ]), @gl.STATIC_DRAW
    @gl.enableVertexAttribArray texCoordLocation
    @gl.vertexAttribPointer texCoordLocation, 2, @gl.FLOAT, false, 0, 0

    @texture = @gl.createTexture()
    @gl.bindTexture @gl.TEXTURE_2D, @texture
    @gl.texParameteri @gl.TEXTURE_2D, @gl.TEXTURE_WRAP_S, @gl.CLAMP_TO_EDGE
    @gl.texParameteri @gl.TEXTURE_2D, @gl.TEXTURE_WRAP_T, @gl.CLAMP_TO_EDGE
    @gl.texParameteri @gl.TEXTURE_2D, @gl.TEXTURE_MIN_FILTER, @gl.LINEAR
    @gl.pixelStorei @gl.UNPACK_FLIP_Y_WEBGL, true

  input_state: (port, device, index, id) =>
    @inputs[port][id] if port of @inputs

  video_refresh: (_data, @width, @height, pitch) =>
    @gl.canvas.width = @width
    @gl.canvas.height = @height
    @gl.viewport 0, 0, @width, @height
    switch @pixelFormat
      when @core.PIXEL_FORMAT_0RGB1555
        data = new Uint16Array _data
        type = @gl.UNSIGNED_SHORT_5_5_5_1
        format = @gl.RGB
      when @core.PIXEL_FORMAT_XRGB8888
        data = new Uint8Array _data
        format = @gl.RGBA
        type = @gl.UNSIGNED_BYTE
      when @core.PIXEL_FORMAT_RGB565
        data = new Uint16Array @width * @height
        _data = new DataView _data.buffer, _data.byteOffset, _data.byteLength
        for line in [0...@height]
          for pixel in [0...@width]
            data[line * @width + pixel] = _data.getUint16(line * pitch + pixel * 2, true)
        format = @gl.RGB
        type = @gl.UNSIGNED_SHORT_5_6_5
    @gl.texImage2D @gl.TEXTURE_2D, 0, format, @width, @height, 0, format, type, data
    @gl.drawArrays @gl.TRIANGLES, 0, 6

  audio_sample_batch: (left, right, frames) =>
    i = 0
    while i < @bufIndex
      if @buffers[i].endTime < @audio.currentTime
        [buf] = @buffers.splice i, 1
        @buffers[@numBuffers - 1] = buf
        i--
        @bufIndex--
      i++
    count = 0
    while frames
      fill = @buffers[@bufIndex].length - @bufOffset
      if fill > frames
        fill = frames
      @buffers[@bufIndex].copyToChannel (new Float32Array left, count * 4, fill), 0, @bufOffset
      @buffers[@bufIndex].copyToChannel (new Float32Array right, count * 4, fill), 1, @bufOffset
      @bufOffset += fill
      count += fill
      frames -= fill
      if @bufOffset == @bufferSize
        if @bufIndex == @numBuffers - 1
          break
        if @bufIndex
          startTime = @buffers[@bufIndex - 1].endTime
        else
          startTime = @audio.currentTime
        @buffers[@bufIndex].endTime = startTime + @buffers[@bufIndex].duration
        source = @audio.createBufferSource()
        source.buffer = @buffers[@bufIndex]
        source.connect @audio.destination
        source.start startTime
        @bufIndex++
        @bufOffset = 0
    count

  setVariable: (key, value) ->
    @variables[core][key] = value
    @variablesUpdate = true

  log: (level, msg) ->
    console.log msg

  environment: (cmd, value) =>
    switch cmd
      when @core.ENVIRONMENT_GET_LOG_INTERFACE
        @log
      when @core.ENVIRONMENT_SET_PIXEL_FORMAT
        @pixelFormat = value
      when @core.ENVIRONMENT_GET_VARIABLE_UPDATE
      else
        console.log "Unknown environment command #{cmd}"

  frame: (now) =>
    return if not @running
    requestAnimationFrame @frame
    elapsed = now - @then
    if elapsed > @fpsInterval
      @then = now - elapsed % @fpsInterval
      @core.run()

  start: ->
    @running = true
    @frame()

  stop: ->
    @running = false

  deinit: ->
    @stop()