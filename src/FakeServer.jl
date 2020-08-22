module FakeServer

using HTTP
using Sockets

abstract type AbstractFakeServer end;
abstract type AbstractFakeResource end;
abstract type AbstractConnection end;

export EchoResource, InteractiveResource, ErrorResource
export waitnconnected, waitnwritten, waitnreceived

struct DefaultServer <: AbstractFakeServer
    tcpserver::Sockets.TCPServer
    task::Task
    default::AbstractFakeResource
    resources::Dict{AbstractString, AbstractFakeResource}
end
DefaultServer(tcpserver, task, default) = DefaultServer(tcpserver, task, default, Dict{AbstractString, AbstractFakeServer}())

Base.get(server::DefaultServer, key::AbstractString) = get(server.resources, key,server.default)
Base.length(server::DefaultServer) = length(server.resources)
Base.getindex(server::DefaultServer, key::AbstractString) = getindex(server.resources, key)
Base.setindex!(server::DefaultServer,resource::AbstractFakeResource, key::AbstractString) = setindex!(server.resources, resource, key)
abstract type AbstractResourceType end;
struct Echo <: AbstractResourceType end
struct Error <: AbstractResourceType end
struct Interactive <: AbstractResourceType end

struct FakeResource{T <: AbstractResourceType}  <: AbstractFakeResource  
    connections::Array{AbstractConnection}
    option
end
FakeResource{T}(option=nothing) where T = FakeResource{T}(AbstractConnection[], option)
Base.length(resource::FakeResource) = length(resource.connections)
Base.getindex(resource::FakeResource,args...) = getindex(resource.connections, args...)
Base.push!(resource::FakeResource, connection::AbstractConnection) = push!(resource.connections, connection)

waitnconnected(resource::FakeResource, n::Integer; timeout::Real=3.0) = timedwait(timeout) do
    length(resource.connections)>=n
end === :ok

EchoResource(;greeting::AbstractString="")=FakeResource{Echo}(greeting)
ErrorResource(;statuscode::UInt16=UInt16(404))=FakeResource{Error}(statuscode)
InteractiveResource(;autoclose::Bool=true)=FakeResource{Interactive}(autoclose)

mutable struct Connection <: AbstractConnection
    io::IO
    received::Array{Any}
    nwritten::Integer
    channel::Channel{Any}
end

Connection(io::IO)=Connection(io,Any[],0, Channel(32))
waitnwritten(conn::Connection, n::Integer; timeout::Real=3.0) = timedwait(timeout) do
    conn.nwritten >= n
end === :ok

waitnreceived(conn::Connection, n::Integer; timeout::Real=3.0) = timedwait(timeout) do
    length(conn.received) >= n
end === :ok

function listen(port::UInt16, args...;
                listenfn::Function=HTTP.WebSockets.listen, 
                defaultresource=EchoResource(), kwargs...)
    tcpserver = Sockets.listen(ip"127.0.0.1", port) 
    task = @async try 
                    s = wait()
                    listenfn("127.0.0.1", port, args...;server=tcpserver, kwargs...) do io
                            serve(s,io)
                        end
                catch e
                    @debug "caught error" e
                    if !isa(e, Base.IOError) 
                        rethrow()
                    end
                end
    server =  DefaultServer(tcpserver, task, defaultresource)
    while !istaskstarted(task)
        yield()
    end
    schedule(task, server)
    return server
end

function serve(server::AbstractFakeServer, io::IO) 
    #each serve() is in an independent coroutine.
    #we need to catch and show errors to make debuging easier.
    try
        target = gettarget(io)
        resource = get(server, target)
        serve(resource, io)
    catch e 
        @error "caught error in serve" e
        rethrow()
    end
end

function serve(resource::AbstractFakeResource, io::IO)
    connection = Connection(io)
    push!(resource, connection)
    handle(resource, connection)
end

function handle(resource::FakeResource{Error},connection::Connection)
    closewrite(connection.io; statuscode=resource.option)
end

function handle(resource::FakeResource{Echo}, connection::Connection) 
    if length(resource.option) > 0
        write(connection, resource.option)
    end
    while !eof(connection.io)
        data = readavailable(connection)
        if length(data) > 0
            write(connection, data)
        end
    end
end

function handle(resource::FakeResource{Interactive}, connection::Connection)
    write_task = handle_write(connection)
    handle_read(connection)
    if resource.option
        put!(connection, nothing)
    end
    wait(write_task)
end

function handle_write(connection::Connection)
    @async try
    #catch exception in async
        while isopen(connection.channel)
            data = take!(connection.channel)
            if data === nothing
                break
            end
            write(connection, data)
        end
    catch e
        @error "caught error in handle write" e
    finally
        close(connection.channel)
    end
end

function handle_read(connection::Connection) 
    try
        while !eof(connection.io)
            readavailable(connection)
        end
    catch e
        @error "caught error in handle_read(::Connection)" e
    end
end

function Base.readavailable(conn::Connection)
    data = readavailable(conn.io)
    if length(data) > 0
        push!(conn.received, data)
    end
    return data
end

function Base.write(conn::Connection, data) 
    write(conn.io, data)
    conn.nwritten += 1
end

Base.put!(conn::Connection, x) = put!(conn.channel, x)

gettarget(ws::HTTP.WebSockets.WebSocket) = ws.request.target
gettarget(http::HTTP.Stream) = http.message.target

function Base.close(server::DefaultServer)
    try
        close(server.tcpserver)
        wait(server.task)
    catch e
        @error "caught error in stop(::DefaultServer" e
        rethrow()
    end
end

end #module FakeServer
