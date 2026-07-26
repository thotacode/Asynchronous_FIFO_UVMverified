onfinish stop
run -all
coverage report -summary -recursive
coverage report -detail -all
coverage save simul_boundary_final.ucdb
exit