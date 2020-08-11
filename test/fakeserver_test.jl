using OpenTrick

@testset "FakeServer" begin
    max_timeout = 3.0
    @testset "Fake HTTP.WebSockets server" begin
        port = UInt16(1891)
        server = FakeServer.listen(port)
        @testset "echo resource" begin
            io = opentrick(HTTP.WebSockets.open, "ws://127.0.0.1:$port/path/to/echo")  
            @test 5 == write(io, "hello")
            @test String(readavailable(io)) == "hello"
            resource = get(server, "/path/to/echo")
            @test length(server) == 0 #since we are using the default resource
            @test length(resource) == 1
            @test length(resource[1].received) == 1
            close(io)
        end

        @testset "echo with greeting" begin
            resource = EchoResource(;greeting="Welcome!")
            server["/path/to/greeting"] = resource
            io = opentrick(HTTP.WebSockets.open, "ws://127.0.0.1:$port/path/to/greeting")
            @test waitnconnected(resource, 1; timeout=max_timeout)
            @test waitnwritten(resource[1], 1; timeout=max_timeout)
            t = @async String(readavailable(io)) 
            @test timedwait(()->istaskdone(t), max_timeout) === :ok
            @test fetch(t) == "Welcome!"
        end

        @testset "interactive resource" begin
            resource = InteractiveResource()
            server["/path/to/interactive"] = resource
            io = opentrick(HTTP.WebSockets.open, "ws://127.0.0.1:$port/path/to/interactive")
            t = @async readavailable(io)
            @test waitnconnected(resource, 1;timeout=max_timeout)
            @test length(resource[1].received) == 0
            @test resource[1].nwritten == 0
            @test t.state == :runnable
            put!(resource[1], "Hi there!")
            @test waitnwritten(resource[1], 1)
            @test timedwait(()->istaskdone(t), max_timeout) === :ok
            @test String(fetch(t)) == "Hi there!"
            write(io, "message 1")
            write(io, "message 2")
            @test waitnreceived(resource[1], 2;timeout=max_timeout)
            @test length(resource[1].received) == 2
            @test String(resource[1].received[1]) == "message 1"
            @test String(resource[1].received[2]) == "message 2"
            close(io)
        end

        @testset "interactive auto close is false" begin
            resource = InteractiveResource(autoclose=false)
            server["/path/to/interactive/manual"] = resource
            io = opentrick(HTTP.WebSockets.open, "ws://127.0.0.1:$port/path/to/interactive/manual")
            t = @async close(io)
            @test timedwait(()->istaskdone(t), max_timeout) === :timed_out
            put!(resource[1], nothing)
            @test timedwait(()->istaskdone(t), max_timeout) === :ok
            @test fetch(t) === nothing
        end

        @testset "resource not found" begin
            resource = ErrorResource()
            server["/not/found"]=resource
            io = opentrick(HTTP.WebSockets.open, "ws://127.0.0.1:$port/not/found")
            @test_throws HTTP.WebSockets.WebSocketError readavailable(io)
            close(io)
        end
        close(server)
    end
end