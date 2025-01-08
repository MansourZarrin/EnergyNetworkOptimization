using Test
using JuMP
using HiGHS

@testset "Energy Network Optimization Tests" begin
    model = Model(HiGHS.Optimizer)

    @variable(model, x >= 0)
    @objective(model, Min, x)
    optimize!(model)

    @testset "Basic Tests" begin
        @test isapprox(value(x), 0.0, atol=1e-3)
    end
end

