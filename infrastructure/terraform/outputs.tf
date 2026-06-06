output "k8s_node_inventory" {
  description = "Declarative inventory for managed k3s nodes."
  value = [
    {
      name = module.k8s_master1.vm_name
      ip   = module.k8s_master1.static_ip
    },
    {
      name = module.k8s_master2.vm_name
      ip   = module.k8s_master2.static_ip
    },
    {
      name = module.k8s_master3.vm_name
      ip   = module.k8s_master3.static_ip
    },
    {
      name = module.k8s_worker1.vm_name
      ip   = module.k8s_worker1.static_ip
    },
    {
      name = module.k8s_worker2.vm_name
      ip   = module.k8s_worker2.static_ip
    },
  ]
}
