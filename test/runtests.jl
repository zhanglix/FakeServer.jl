using Test
using FakeServer
using HTTP


using Logging
global_logger(ConsoleLogger(stderr,Logging.Debug))
disable_logging(Logging.LogLevel(-10000))
HTTP.DEBUG_LEVEL[]=10

@testset "all tests" begin
    include("fakeserver_test.jl")

end